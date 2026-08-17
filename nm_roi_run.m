function nm_roi_run(args)
% Neuromorphometrics ROI averaging (SPM12)
% MATLAB R2013b-safe, self-contained helpers
%
% Inputs (fields in args):
%   maskdir     : char, folder with binary masks (.nii/.nii.gz)
%   images      : cellstr, target (thresholded SPM) images
%   ignorezeros : bool, treat zeros in target as missing
%   outdir      : char, output directory
%   outname     : char, base name (no extension)
%   perimgcsv   : bool, also save per-image CSVs
%   strategy    : 'mask_to_stat' (keep stats as-is; align masks to stat grid)
%
% Output spreadsheet: one ROW per mask; first col = ROI name; one col per image.

assert(exist('spm','file')==2 || exist('spm','file')==6, ...
    'SPM12 not found on path. Add SPM12 to MATLAB path and retry.');

% ---- Validate ----
assert(ischar(args.maskdir) && exist(args.maskdir,'dir')==7, 'Invalid mask directory.');
assert(iscell(args.images) && ~isempty(args.images), 'No target images provided.');
assert(ischar(args.outdir) && exist(args.outdir,'dir')==7, 'Invalid output directory.');
if ~isfield(args,'outname') || isempty(args.outname), args.outname = 'roi_averages'; end
if ~isfield(args,'ignorezeros'), args.ignorezeros = false; end
if ~isfield(args,'strategy') || ~strcmpi(args.strategy,'mask_to_stat')
    args.strategy = 'mask_to_stat';
end

% ---- Gather masks ----
masks = list_nii_files_local(args.maskdir);
assert(~isempty(masks), 'No *.nii or *.nii.gz masks found in mask directory.');
[~,ord] = sort(lower(cellfun(@file_noext_local, masks, 'UniformOutput', false)));
masks = masks(ord);

fprintf('[NM-ROI] Masks: %d | Targets: %d\n', numel(masks), numel(args.images));

% ---- Reference: FIRST TARGET IMAGE (stat map) ----
VrefImg = spm_vol(args.images{1});  % leave stats untouched
dimsRef = VrefImg.dim;
Mref    = VrefImg.mat;

% ---- Prepare adjusted masks (align to stat grid) ----
tmpDir = fullfile(tempdir, ['nm_roi_tmp_' datestr(now,'yyyymmdd_HHMMSSFFF')]);
if ~exist(tmpDir,'dir'), mkdir(tmpDir); end
cleanupTmp = true;

adjMasks = cell(size(masks));
for i = 1:numel(masks)
    adjMasks{i} = adjust_mask_to_image_local(masks{i}, VrefImg, tmpDir);
end

% Keep images unchanged
adjImages = args.images;

% ---- Compute ROI means (NaN-safe; optional zero-ignore) ----
fprintf('[NM-ROI] Computing ROI means...\n');
[tblData, colNames, rowNames] = compute_roi_means_local(adjMasks, adjImages, args.ignorezeros, VrefImg);

% ---- Save main table (one ROW per mask) ----
outfileBase = fullfile(args.outdir, args.outname);
[outMainPath, wroteExcel] = save_main_table_local(outfileBase, tblData, colNames);
fprintf('[NM-ROI] Saved: %s\n', outMainPath);

% ---- Optional per-image CSVs ----
if isfield(args,'perimgcsv') && args.perimgcsv
    save_per_image_csvs_local(outMainPath, tblData, colNames, rowNames);
    fprintf('[NM-ROI] Per-image CSVs saved.\n');
end

% ---- Cleanup ----
if cleanupTmp && exist(tmpDir,'dir')
    try rmdir(tmpDir,'s'); catch, end
end

if ~wroteExcel
    warning(['Excel not available. Main output written as CSV. ', ...
             'Open in Excel and Save As .xlsx if needed.']);
end
fprintf('[NM-ROI] Done.\n');

end % nm_roi_run


% ===================== LOCAL HELPERS (R2013b-safe) =====================

function paths = list_nii_files_local(d)
    f1 = dir(fullfile(d,'*.nii'));
    f2 = dir(fullfile(d,'*.nii.gz'));
    n1 = numel(f1); n2 = numel(f2);
    paths = cell(n1+n2,1); idx = 1;
    for k = 1:n1
        if ~isfield(f1,'isdir') || ~f1(k).isdir
            paths{idx} = fullfile(d, f1(k).name); idx = idx+1;
        end
    end
    for k = 1:n2
        if ~isfield(f2,'isdir') || ~f2(k).isdir
            paths{idx} = fullfile(d, f2(k).name); idx = idx+1;
        end
    end
    if idx>1, paths = paths(1:idx-1); else paths = {}; end
    paths = paths(:);
end

function name = file_noext_local(p)
    [~,n,ext] = fileparts(p);
    if strcmpi(ext,'.gz')
        [~,n2,ext2] = fileparts(n);
        if strcmpi(ext2,'.nii'), n = n2; end
    end
    name = n;
end

function closeEnough = mat_close_local(A,B)
    closeEnough = max(abs(A(:)-B(:))) <= 1e-3;  % relaxed tolerance
end

function outMask = adjust_mask_to_image_local(maskPath, VrefImg, outDir)
% Bring a binary mask onto the stat-map grid (keeps stats untouched)
% - If orientation differs: reslice mask -> image space (NN)
% - Else if only dims differ: crop/pad mask to image dims (outside=0)
% - Else: mask already matches

    Vm = spm_vol(maskPath);
    sameOrient = mat_close_local(Vm.mat, VrefImg.mat);

    if sameOrient && all(Vm.dim(:)==VrefImg.dim(:))
        outMask = maskPath; 
        return;
    end

    if sameOrient && any(Vm.dim(:)~=VrefImg.dim(:))
        % Crop/pad mask to the reference dims (fill outside with 0)
        [msk,~] = spm_read_vols(Vm);
        sz = size(msk); if numel(sz)<3, sz(3)=1; end
        newM = zeros(VrefImg.dim(1), VrefImg.dim(2), VrefImg.dim(3)); % 0 = outside ROI
        a = min(VrefImg.dim(1), sz(1));
        b = min(VrefImg.dim(2), sz(2));
        c = min(VrefImg.dim(3), sz(3));
        newM(1:a,1:b,1:c) = (msk(1:a,1:b,1:c) > 0);
        if ~exist(outDir,'dir'), mkdir(outDir); end
        bn = file_noext_local(maskPath);
        outMask = fullfile(outDir, ['cm_' bn '.nii']);
        Vw = VrefImg; 
        Vw.fname   = outMask; 
        Vw.descrip = 'NM-ROI: mask crop/pad to stat grid'; 
        Vw.dt      = [spm_type('uint8') spm_platform('bigend')];
        spm_write_vol(Vw, uint8(newM));
        return;
    end

    % Orientation differs: reslice mask -> image space (nearest-neighbor)
    % NOTE: spm_reslice writes into the SOURCE (mask) directory, not outDir.
    prefix = 'rm';  % output prefix
    P = char(VrefImg.fname, maskPath); % reference first, source second
    flags = struct('mask',1,'mean',0,'interp',0,'which',1,'wrap',[0 0 0],'prefix',prefix);
    spm_reslice(P, flags);

    % Build expected filenames where SPM writes them (mask's folder)
    cand1 = spm_file(maskPath,'prefix',prefix,'ext','nii'); % typical SPM12
    cand2 = spm_file(maskPath,'prefix',prefix,'ext','img'); % Analyze fallback

    if exist(cand1,'file')
        outMask = cand1; 
        return;
    elseif exist(cand2,'file')
        outMask = cand2; 
        return;
    else
        % Robust fallback search in both source and outDir
        [srcDir,~,~] = fileparts(maskPath);
        d1 = dir(fullfile(srcDir,[prefix,'*.nii']));
        d2 = dir(fullfile(srcDir,[prefix,'*.img']));
        d3 = dir(fullfile(outDir,[prefix,'*.nii']));
        d4 = dir(fullfile(outDir,[prefix,'*.img']));
        if ~isempty(d1), outMask = fullfile(d1(1).name); outMask = fullfile(srcDir,d1(1).name); return; end
        if ~isempty(d2), outMask = fullfile(srcDir,d2(1).name); return; end
        if ~isempty(d3), outMask = fullfile(outDir,d3(1).name); return; end
        if ~isempty(d4), outMask = fullfile(outDir,d4(1).name); return; end
        error('Resliced mask not found for %s (checked %s and %s).', maskPath, srcDir, outDir);
    end
end


function [tblData, colNames, rowNames] = compute_roi_means_local(maskPaths, imgList, ignorezeros, VrefImg)
% One ROW per mask, one COLUMN per image (plus 'ROI')
    nm = numel(maskPaths); ni = numel(imgList);

    colNames = cell(1,ni+1); colNames{1} = 'ROI';
    for j=1:ni, colNames{1+j} = file_noext_local(imgList{j}); end

    rowNames = cell(nm,1);
    tblData  = cell(nm,ni+1);
    for i=1:nm
        rowNames{i} = file_noext_local(maskPaths{i});
        tblData{i,1} = rowNames{i};
    end

    % Verify all masks match the reference image grid
    for i=1:nm
        Vm = spm_vol(maskPaths{i});
        if any(Vm.dim ~= VrefImg.dim) || ~mat_close_local(Vm.mat, VrefImg.mat)
            error(['Adjusted mask still mismatched: ' maskPaths{i}]);
        end
    end

    % Compute
    for j=1:ni
        Vimg = spm_vol(char(imgList{j}));
        if any(Vimg.dim ~= VrefImg.dim) || ~mat_close_local(Vimg.mat, VrefImg.mat)
            error(['Target image grid differs from FIRST target: ' imgList{j}]);
        end
        img = spm_read_vols(Vimg);
        valid = isfinite(img);
        if ignorezeros, valid = valid & (img~=0); end

        for i=1:nm
            Vm  = spm_vol(maskPaths{i});
            msk = spm_read_vols(Vm);
            % roi = (msk>0) & valid;          
            roi = ((msk>0)&(~isnan(msk))) & valid;
            vals = img(roi);
            if isempty(vals), mu = 0; else mu = mean(vals); end   % Changed from mean to median
            tblData{i,1+j} = mu;
        end
    end
end

function [outMainPath, wroteExcel] = save_main_table_local(basePathNoExt, tblData, colNames)
    wroteExcel = false;
    xlsxPath = [basePathNoExt '.xlsx'];
    try
        if ispc && usejava('jvm')
            out = [colNames; tblData];
            xlswrite(xlsxPath, out);
            outMainPath = xlsxPath; wroteExcel = true; return;
        end
    catch
        % fall through
    end
    csvPath = [basePathNoExt '.csv'];
    write_csv_local(csvPath, tblData, colNames);
    outMainPath = csvPath;
end

function write_csv_local(outCSV, tblData, colNames)
    fid = fopen(outCSV,'w'); assert(fid>0, 'Cannot open %s', outCSV);
    for c=1:numel(colNames)
        fprintf(fid,'%s%s', csvsafe_local(colNames{c}), iff_local(c<numel(colNames),',',''));
    end
    fprintf(fid,'\n');
    nrow = size(tblData,1); ncol = size(tblData,2);
    for r=1:nrow
        for c=1:ncol
            v = tblData{r,c};
            if ischar(v), s = csvsafe_local(v);
            elseif isempty(v), s = '';
            else, s = sprintf('%.10g', v);
            end
            fprintf(fid,'%s%s', s, iff_local(c<ncol,',',''));
        end
        fprintf(fid,'\n');
    end
    fclose(fid);
end

function save_per_image_csvs_local(outMainPath, tblData, colNames, rowNames)
% One CSV per image with columns: ROI,Mean
    [p,base,~] = fileparts(outMainPath);
    if isempty(p), p = pwd; end
    nimg = numel(colNames) - 1;
    if nimg <= 0, return; end
    for j = 1:nimg
        imgLabel = colNames{1+j};
        imgLabelSafe = imgLabel;
        imgLabelSafe(imgLabelSafe==' ' | imgLabelSafe==filesep | imgLabelSafe==':') = '_';
        outCSV = fullfile(p, sprintf('%s__%s.csv', base, imgLabelSafe));
        fid = fopen(outCSV,'w'); assert(fid>0, 'Cannot open %s', outCSV);
        fprintf(fid,'ROI,Mean\n');
        nroi = numel(rowNames);
        for i = 1:nroi
            v = tblData{i, 1+j};
            if isempty(v) || ~isfinite(v), vstr = ''; else vstr = sprintf('%.10g', v); end
            fprintf(fid,'%s,%s\n', csvsafe_local(rowNames{i}), vstr);
        end
        fclose(fid);
    end
end

function s = csvsafe_local(s)
    if ~ischar(s), s = num2str(s); end
    if any(s==',') || any(s=='"')
        s = strrep(s,'"','""'); s = ['"' s '"'];
    end
end

function o = iff_local(cond,a,b)
    if cond, o=a; else o=b; end
end
