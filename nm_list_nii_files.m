function paths = nm_list_nii_files(d)
% Backward-compatible file lister for R2013b (no 'folder' field in dir)
% Returns a column cell array of full paths to *.nii and *.nii.gz

    if nargin < 1 || ~exist(d,'dir')
        error('nm_list_nii_files:InvalidDir','Invalid directory: %s',char(d));
    end

    f1 = dir(fullfile(d,'*.nii'));
    f2 = dir(fullfile(d,'*.nii.gz'));

    n1 = numel(f1);
    n2 = numel(f2);
    paths = cell(n1+n2,1);

    % Build full paths without using the non-existent 'folder' field
    for k = 1:n1
        paths{k} = fullfile(d, f1(k).name);
    end
    for k = 1:n2
        paths{n1+k} = fullfile(d, f2(k).name);
    end

    % Make sure it’s a column
    paths = paths(:);
end


function name = nm_file_noext(p)
    [~,n,ext] = fileparts(p);
    if strcmpi(ext,'.gz')
        % handle .nii.gz
        [~,n2,ext2] = fileparts(n);
        if strcmpi(ext2,'.nii'), n = n2; end
    end
    name = n;
end

function outMasks = nm_reslice_masks_to_ref(maskPaths, refImg, outDir)
% Reslice masks to refImg space using spm_reslice, NN interpolation
    if ~exist(outDir,'dir'), mkdir(outDir); end
    outMasks = cell(size(maskPaths));
    for i=1:numel(maskPaths)
        P = char(refImg, maskPaths{i}); % reference first, source second
        flags = struct('mask',1,'mean',0,'interp',0,'which',1,'wrap',[0 0 0],'prefix','r');
        cwd = pwd;
        try
            cd(outDir);
            spm_reslice(P,flags);
            src = maskPaths{i};
            [~,n,ext] = fileparts(src);
            if strcmpi(ext,'.gz')
                % spm_reslice typically outputs .nii
                nn = nm_file_noext(src);
            else
                nn = n;
            end
            rfile = fullfile(outDir, ['r' nn '.nii']);
            if ~exist(rfile,'file')
                dd = dir(fullfile(outDir,'r*.nii'));
                assert(~isempty(dd), 'Resliced file not found for %s', src);
                rfile = fullfile(dd(1).folder, dd(1).name);
            end
            outMasks{i} = rfile;
        catch ME
            cd(cwd);
            error('Reslice failed for %s: %s', maskPaths{i}, ME.message);
        end
        cd(cwd);
    end
end

function [tblData, colNames, rowNames] = nm_compute_roi_means(maskPaths, imgList, ignorezeros)
% Returns:
%   tblData : cell (nROI x (1+nImg)) with {ROI_name, mean1, mean2, ...}
%   colNames: {'ROI', <img1>, <img2>, ...}
%   rowNames: ROI base names

    nm = numel(maskPaths);
    ni = numel(imgList);

    colNames = cell(1,ni+1);
    colNames{1} = 'ROI';
    for j=1:ni
        [~,n,ext] = fileparts(imgList{j});
        if strcmpi(ext,'.gz')
            n = nm_file_noext(imgList{j});
        end
        colNames{1+j} = n;
    end

    rowNames = cell(nm,1);
    tblData  = cell(nm,ni+1);
    for i=1:nm
        rowNames{i} = nm_file_noext(maskPaths{i});
        tblData{i,1} = rowNames{i};
    end

    % Reference geometry: first image
    Vref  = spm_vol(char(imgList{1}));
    dimsR = Vref.dim;
    MR    = Vref.mat;

    % Check all masks match ref geometry (if not resliced)
    for i=1:nm
        Vm = spm_vol(maskPaths{i});
        if any(Vm.dim ~= dimsR) || max(abs(Vm.mat(:)-MR(:)))>1e-5
            error(['Mask does not match image geometry: ' maskPaths{i} sprintf('\n') ...
                   'Enable "Reslice masks to first image space" and re-run.']);
        end
    end

    % Compute over each image
    for j=1:ni
        Vimg = spm_vol(char(imgList{j}));
        img  = spm_read_vols(Vimg); % double
        valid = isfinite(img);
        if ignorezeros
            valid = valid & (img>0);  %%%%% Take only positive values
        end

        for i=1:nm
            Vm  = spm_vol(maskPaths{i});
            msk = spm_read_vols(Vm);
            roi = (msk>0) & valid;
            vals = img(roi);
            if isempty(vals)
                mu = 0; % avoid NaN: define empty as 0
            else
                mu = mean(vals);
            end
            tblData{i,1+j} = mu;
        end
    end
end

function [outMainPath, wroteExcel] = nm_save_main_table(basePathNoExt, tblData, colNames, rowNames)
% Save main table as Excel if possible (one row per mask), else CSV fallback.
% Returns full path actually written + boolean wroteExcel.

    wroteExcel = false;

    % Prefer .xlsx
    xlsxPath = [basePathNoExt '.xlsx'];
    try
        if ispc && usejava('jvm')
            % xlswrite available; build cell array with header row
            out = [colNames; tblData];
            xlswrite(xlsxPath, out);
            outMainPath = xlsxPath;
            wroteExcel = true;
            return;
        end
    catch
        % fall through to CSV
    end

    % CSV fallback
    csvPath = [basePathNoExt '.csv'];
    nm_write_csv(csvPath, tblData, colNames);
    outMainPath = csvPath;
end

function nm_write_csv(outCSV, tblData, colNames)
    fid = fopen(outCSV,'w');
    assert(fid>0, 'Cannot open %s for writing.', outCSV);
    % header
    for c=1:numel(colNames)
        fprintf(fid,'%s%s', nm_csvsafe(colNames{c}), ternary(c<numel(colNames),',',''));
    end
    fprintf(fid,'\n');
    % data (one row per mask)
    nrow = size(tblData,1); ncol = size(tblData,2);
    for r=1:nrow
        for c=1:ncol
            val = tblData{r,c};
            if ischar(val), s = nm_csvsafe(val);
            elseif isempty(val), s = '';
            else, s = sprintf('%.10g', val);
            end
            fprintf(fid,'%s%s', s, ternary(c<ncol,',',''));
        end
        fprintf(fid,'\n');
    end
    fclose(fid);
end

function s = nm_csvsafe(s)
    if ~ischar(s), s = num2str(s); end
    if any(s==',') || any(s=='"')
        s = strrep(s,'"','""');
        s = ['"' s '"'];
    end
end

function out = ternary(cond, a, b)
    if cond, out = a; else out = b; end
end
