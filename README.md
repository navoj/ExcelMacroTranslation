# FEDC Test Group Excel Macro Port

A Perl 5 port of the FEDC test group's Excel **MasterDataProcess** workflow for
characterizing thin-film transistors (TFTs) from autoprobe sweep data.

The original workflow is a `ProcessTFTAuto` VBA macro that drives an
`AnalysisMaster_Autoprobe_Prod` workbook: it loads raw sweep files into the
workbook, lets ~13 interlinked worksheets compute the device parameters, reads
the results into a Summary sheet, and prints a set of diagnostic charts. This
project reproduces the worksheet **calculations**, the **VBA** orchestration,
and the **charts** as a self-contained Perl program — no Excel required.

## What it computes

For every device (three raw files: forward `hf_ids_vgs`, reverse
`hf_ids_vgs-rev`, and output `hf_ids_vds`) the program produces the same 25
parameters the Excel Summary sheet reports:

| Group | Parameters |
|-------|------------|
| Threshold / transconductance | `Vt`, `gm`, `Vt_10`, `gm_10` |
| Subthreshold slope | `Subthreshold`, `Subthreshold_10` |
| Mobility | `Sat Mobility`, `Mobility_0.5/0.2/0.1` |
| On/off & currents | `On_Off_20x0`, `On_Off_20xN15`, `Idrive`, `Ileak`, `Ireverse` |
| Gate leakage | `IG_N5`, `IG_20` |
| Channel-length modulation | `Lambda_10/15/20` |
| Contact resistance (Moyer) | `VD_Offset`, `VD_Resistance`, `VD_Intercept`, `R_Inf` |
| Hysteresis | `Hysteresis_S` |

The extraction faithfully mirrors the spreadsheet: cubic-midpoint interpolation
of the raw sweeps, centered moving-average smoothing, `sqrt(IDS)` threshold
extraction by linear fit at the point of maximum slope, log-slope subthreshold
fits, `gd`-based low-field mobility, saturation `Ids-Vds` channel-length
modulation, and the Moyer cubic-fit contact-resistance extrapolation.

## Source files

| File | Role |
|------|------|
| `TFTAnalysis.pm` | The calculations: file readers, interpolation, smoothing, and all parameter extraction (the "worksheet formulas" + VBA fit routines). |
| `TFTReport.pm` | Output: the parameter Summary (CSV + XLSX) and the per-device charts (gnuplot). |
| `process_tft.pl` | Command-line driver — the `ProcessTFTAuto` equivalent. |
| `lo-convert.sh` | Headless LibreOffice document converter used to extract the original `.xls` formulas (see below). |
| `validate.pl` | Compares the Perl output against an Excel-produced Summary. |
| `config.json` | Example run configuration. |
| `t/03_analysis.t` | Regression test against reference values. |

## Usage

By default `process_tft.pl` searches the directory given to `--lot`
**recursively**: any folder that contains `hf_ids_*` device files is treated as
a wafer. The same command therefore works whether you point it at a single
wafer, one lot of `Wafer_*` folders, or a whole tree of lots and wafers.

```sh
# One wafer directory:
perl process_tft.pl --lot t/E1538-001/Wafer_1

# One lot (all of its Wafer_* subdirectories):
perl process_tft.pl --lot /path/to/E1538-001

# A parent folder holding many lots, each with many wafers -> everything found
# beneath it is processed in one pass:
perl process_tft.pl --lot /data/autoprobe --out ./results

# Or drive everything from a config file:
perl process_tft.pl -c config.json --out ./out
```

### Recursively processing a folder of subfolders

Point `--lot` at any parent directory and the script walks the entire tree,
processing every wafer it finds no matter how deeply it is nested — for example:

```
/data/autoprobe/
├── E1538-001/
│   ├── Wafer_1/    ← hf_ids_vgs_*, hf_ids_vgs-rev_*, hf_ids_vds_* ...
│   └── Wafer_2/
└── E1607-001/
    ├── Panel_1/
    └── Panel_2/
```

```sh
# Recurse over the whole tree (recursion is on by default):
perl process_tft.pl --lot /data/autoprobe --out ./results
```

- Every directory containing measurement files is analysed as one wafer; the
  lot and wafer names are taken from the file names, so the folder layout can be
  anything.
- With `--out DIR`, each wafer's Summary and `charts/` are written to its own
  `DIR/<Lot>_Wafer_<W>/` subfolder, so nothing collides across wafers. Without
  `--out`, results are written next to each wafer's data (as the Excel workflow
  wrote its `.prn` files).
- Use `--no-recursive` to search only one level below `--lot` (the classic
  "lot of `Wafer_*` folders" behaviour), or name specific wafers with one or
  more `--wafer NAME` options.

Outputs per wafer:
- `<Lot>_Wafer_<W>_Summary.csv` and `.xlsx` — the 29-column parameter table.
- `charts/UID<uid>@<site>_*.png` — Vt extraction (1 V and 10 V), transfer /
  subthreshold, output curves, biased gate current, contact resistance, and
  hysteresis plots.

### Gate-dielectric constants

Mobility and capacitance depend on the gate dielectric, which differs by lot
(each lot is processed with a specific AnalysisMaster). Set them with
`--eps` / `--tox` (or in the config). Defaults match the **SiO2** autoprobe
master used for the bundled E1538 test data (`eps=3.9`, `tox=2000` Å).

## Validation

`validate.pl` checks the port against the Excel-produced
`E1538-001_Wafer_1_Summary.xls` (8 devices). With the correct dielectric
constants and the linear transfer-sweep interpolation the SiO2 master uses,
**23 of the 25 parameters reproduce the spreadsheet to within 0.5%** (most are
bit-for-bit identical). The exceptions are a ~1% offset on `VD_Intercept` and,
on a single device with an unusually abrupt turn-on, a larger `Vt_10` /
`Sat Mobility` difference where the max-slope extraction is dominated by noise.

```sh
perl t/03_analysis.t     # regression test (uses Test::More)
perl validate.pl         # full per-parameter comparison report
```

Two lot-dependent knobs matter for an exact match:
- **Dielectric constants** (`--eps` / `--tox`) — the E1538 lot used SiO2
  (`eps=3.9`, `tox=2000` Å); a later Al2O3-style master used `eps=7.5`.
- **Transfer interpolation** (`$TFTAnalysis::TRANSFER_INTERP`, default
  `linear`) — the SiO2 master interpolates IDS-VGS sweeps linearly; later
  masters use a cubic estimator (`cubic`). Output curves are always cubic.

## The `lo-convert.sh` helper

Extracting the reference formulas from the original `.xls` masters required a
working headless LibreOffice. On this host the distro LibreOffice fails every
conversion on Wayland, while the confined **snap** build works but cannot see
`/tmp`. `lo-convert.sh` wraps the snap build and stages files through a
snap-accessible work area so any document can be converted:

```sh
./lo-convert.sh AnalysisMaster.xls xlsx        # -> AnalysisMaster.xlsx
./lo-convert.sh book.xls csv /some/output/dir
```

## Requirements

Perl 5 with `Excel::Writer::XLSX` (optional, for `.xlsx` output) and `JSON::PP`;
`gnuplot` for charts. All are used only when present — the core analysis runs on
a stock Perl.
