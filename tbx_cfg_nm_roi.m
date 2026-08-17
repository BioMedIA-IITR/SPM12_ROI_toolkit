function nm_roi = tbx_cfg_nm_roi
% Toolbox config: SPM -> Tools -> Neuromorphometrics ROI Averaging
% MATLAB R2013b-compatible, SPM12

% ---- Mask directory ----
maskdir         = cfg_files;
maskdir.tag     = 'maskdir';
maskdir.name    = 'Mask directory';
maskdir.help    = {'Folder containing binary ROI masks (.nii or .nii.gz).'};
maskdir.filter  = 'dir';
maskdir.ufilter = '.*';
maskdir.num     = [1 1];

% ---- Target images (thresholded SPM maps) ----
images          = cfg_files;
images.tag      = 'images';
images.name     = 'Target images';
images.help     = {'One or more NIfTI images to summarize (e.g., thresholded SPM maps). These are kept unchanged.'};
images.filter   = 'image';
images.ufilter  = '.*';
images.num      = [1 Inf];

% ---- Treat zeros in target as missing ----
ignorezeros         = cfg_menu;
ignorezeros.tag     = 'ignorezeros';
ignorezeros.name    = 'Treat zeros in target as missing';
ignorezeros.help    = {'If Yes, 0-valued voxels in the target images are ignored (useful when masking sets zeros).'};
ignorezeros.labels  = {'Yes','No'};
ignorezeros.values  = {true,false};
ignorezeros.val     = {false};

% ---- Output directory ----
outdir          = cfg_files;
outdir.tag      = 'outdir';
outdir.name     = 'Output directory';
outdir.help     = {'Folder where Excel/CSV will be saved.'};
outdir.filter   = 'dir';
outdir.ufilter  = '.*';
outdir.num      = [1 1];

% ---- Output base name ----
outname         = cfg_entry;
outname.tag     = 'outname';
outname.name    = 'Output base name (no extension)';
outname.help     = {'Example: roi_averages_YYYYMMDD. ".xlsx" preferred on Windows+Excel; CSV fallback otherwise.'};
outname.strtype = 's';
outname.num     = [1 Inf];
outname.val     = {'roi_averages'};

% ---- Also save per-image CSVs ----
perimgcsv           = cfg_menu;
perimgcsv.tag       = 'perimgcsv';
perimgcsv.name      = 'Also save per-image CSVs';
perimgcsv.help      = {'Writes one CSV per image with columns [ROI, Mean].'};
perimgcsv.labels    = {'Yes','No'};
perimgcsv.values    = {true,false};
perimgcsv.val       = {false};

% ---- Branch ----
nm_roi          = cfg_exbranch;
nm_roi.tag      = 'nm_roi';
nm_roi.name     = 'ROI Averaging Kumar Lab';
nm_roi.val      = {maskdir images ignorezeros outdir outname perimgcsv};
nm_roi.help     = {'Computes NaN-safe ROI means with one row per mask. '
                   'Stat maps remain untouched. Masks are auto-aligned to the FIRST target''s grid: '
                   'nearest-neighbor reslice if orientation differs; crop/pad (fill 0) if only size differs.'};
nm_roi.prog     = @run_nm_roi;
nm_roi.vout     = @vout_nm_roi;

end

% ---- Runner wrapper ----
function out = run_nm_roi(job)
args = struct();
args.maskdir     = job.maskdir{1};
args.images      = job.images;
args.ignorezeros = logical(job.ignorezeros);
args.outdir      = job.outdir{1};
args.outname     = job.outname;
args.perimgcsv   = logical(job.perimgcsv);

% Fixed strategy (best practice):
% - Keep stats as-is
% - Align masks to FIRST stat (reslice NN if orientation differs; else crop/pad)
args.strategy = 'mask_to_stat';

nm_roi_run(args);
out = struct([]);
end

function dep = vout_nm_roi(~)
dep = [];
end
