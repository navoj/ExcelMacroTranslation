package TFTReport;

# TFTReport.pm
#
# Output side of the TFT autoprobe analysis: writes the parameter Summary
# (CSV and, if Excel::Writer::XLSX is available, .xlsx) and renders the
# per-device diagnostic charts with gnuplot -- the Perl equivalent of the
# graphs the Excel AnalysisMaster prints for every device.

use strict;
use warnings;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

# Columns written to the Summary, matching the Excel "Summary" sheet.
our @HEADER = (
    'TestDate', 'UID', 'Device ID', 'Site',
    'Vt', 'gm', 'Subthreshold', 'Sat Mobility', 'Mobility_0.5', 'Mobility_0.2',
    'Mobility_0.1', 'Lambda_20', 'Vt_10', 'gm_10', 'Subthreshold_10',
    'On_Off_20x0', 'On_Off_20xN15', 'IG_N5', 'IG_20', 'Lambda_15', 'Lambda_10',
    'Idrive', 'Ileak', 'VD_Offset', 'VD_Resistance', 'VD_Intercept', 'R_Inf',
    'Hysteresis_S', 'Ireverse',
);

# Map header label -> analyze_device result key.
our %KEY = (
    'Vt' => 'Vt', 'gm' => 'gm', 'Subthreshold' => 'Subthreshold',
    'Sat Mobility' => 'SatMobility', 'Mobility_0.5' => 'Mobility_0.5',
    'Mobility_0.2' => 'Mobility_0.2', 'Mobility_0.1' => 'Mobility_0.1',
    'Lambda_20' => 'Lambda_20', 'Vt_10' => 'Vt_10', 'gm_10' => 'gm_10',
    'Subthreshold_10' => 'Subthreshold_10', 'On_Off_20x0' => 'On_Off_20x0',
    'On_Off_20xN15' => 'On_Off_20xN15', 'IG_N5' => 'IG_N5', 'IG_20' => 'IG_20',
    'Lambda_15' => 'Lambda_15', 'Lambda_10' => 'Lambda_10', 'Idrive' => 'Idrive',
    'Ileak' => 'Ileak', 'VD_Offset' => 'VD_Offset',
    'VD_Resistance' => 'VD_Resistance', 'VD_Intercept' => 'VD_Intercept',
    'R_Inf' => 'R_Inf', 'Hysteresis_S' => 'Hysteresis_S', 'Ireverse' => 'Ireverse',
);

# Build one Summary row (arrayref) from a device record.
# $rec = { TestDate, UID, DeviceID, Site, res => <analyze_device hash> }
sub summary_row {
    my ($rec) = @_;
    my @row = ($rec->{TestDate} // '', $rec->{UID}, $rec->{DeviceID}, $rec->{Site});
    for my $h (@HEADER[4 .. $#HEADER]) {
        my $v = $rec->{res}{ $KEY{$h} };
        push @row, defined $v ? $v : '';
    }
    return \@row;
}

sub write_summary_csv {
    my ($path, $rows) = @_;
    open my $fh, '>', $path or die "write_summary_csv $path: $!";
    print $fh join(',', @HEADER), "\n";
    for my $r (@$rows) {
        print $fh join(',', map { _csv($_) } @$r), "\n";
    }
    close $fh;
    return $path;
}

sub _csv {
    my $v = shift;
    return '' unless defined $v;
    $v = qq{"$v"} if $v =~ /[",\n]/;
    return $v;
}

# Optional .xlsx output (only if Excel::Writer::XLSX is installed).
sub write_summary_xlsx {
    my ($path, $rows) = @_;
    return undef unless eval { require Excel::Writer::XLSX; 1 };
    my $wb = Excel::Writer::XLSX->new($path) or return undef;
    my $ws = $wb->add_worksheet('Summary');
    my $bold = $wb->add_format(bold => 1);
    $ws->write_row(0, 0, \@HEADER, $bold);
    my $ri = 1;
    for my $r (@$rows) { $ws->write_row($ri++, 0, $r); }
    $wb->close;
    return $path;
}

# ---------------------------------------------------------------------------
# Charts (gnuplot)
# ---------------------------------------------------------------------------

my $HAVE_GNUPLOT;
sub have_gnuplot {
    return $HAVE_GNUPLOT if defined $HAVE_GNUPLOT;
    $HAVE_GNUPLOT = (system('sh', '-c', 'command -v gnuplot >/dev/null 2>&1') == 0) ? 1 : 0;
    return $HAVE_GNUPLOT;
}

# Write "x y" columns to a temp data file.
sub _datafile {
    my ($dir, $name, @cols) = @_;    # @cols = ([x...],[y...], ...)
    my $path = "$dir/$name.dat";
    open my $fh, '>', $path or die $!;
    my $n = scalar @{ $cols[0] };
    for my $i (0 .. $n - 1) {
        my @v = map { my $x = $_->[$i]; (defined $x && $x eq $x) ? $x : 'NaN' } @cols;
        print $fh join(' ', @v), "\n";
    }
    close $fh;
    return $path;
}

sub _run_gnuplot {
    my ($script) = @_;
    open my $gp, '|-', 'gnuplot' or do { warn "gnuplot: $!"; return 0 };
    print $gp $script;
    close $gp;
    return 1;
}

# Positive-only copy (for log-scale plots).
sub _pos { [ map { (defined $_ && $_ > 0) ? $_ : 'NaN' } @{ $_[0] } ] }

# Generate the diagnostic chart set for one device into $outdir/$printid_*.png.
# Returns the list of PNG paths written.
sub generate_charts {
    my ($res, $outdir, $printid, %opt) = @_;
    return () unless have_gnuplot();
    make_path($outdir) unless -d $outdir;
    my $tmp = tempdir(CLEANUP => 1);
    my $term = $opt{term} || 'pngcairo size 900,600 font "Arial,11" noenhanced';
    my @png;

    my $x1  = $res->{_x1};
    my $x10 = $res->{_x10};
    my $xr  = $res->{_xr};
    my $title = $printid;

    # 1. Transfer / subthreshold: log|IDS| vs VGS (1V and 10V).
    {
        my $d1  = _datafile($tmp, 'tr1',  $x1->{vg},  _pos($x1->{ids}));
        my $d10 = _datafile($tmp, 'tr10', $x10->{vg}, _pos($x10->{ids}));
        my $png = "$outdir/${printid}_Subthresh.png";
        _run_gnuplot(<<"GP") and push @png, $png;
set terminal $term
set output "$png"
set title "Transfer (Subthreshold) - $title"
set xlabel "VGS (V)"; set ylabel "IDS (A)"
set logscale y; set grid; set key top left
plot "$d1" u 1:2 w l lw 2 t "VD=1V", "$d10" u 1:2 w l lw 2 t "VD=10V"
GP
    }

    # 2/3. Vt extraction: sqrt(IDS) vs VGS with the fitted tangent (Vt intercept).
    for my $spec ([ $x1, 'Vt_1', '1V', $res->{Vt} ],
                  [ $x10, 'Vt_10', '10V', $res->{Vt_10} ]) {
        my ($x, $tag, $lbl, $vt) = @$spec;
        my $dd = _datafile($tmp, "sq$tag", $x->{vg}, $x->{sqrt_ids});
        # tangent line y = m*(VGS) + b over [Vt, VGS@maxslope+a bit]
        my $m = $x->{fit_m}; my $b = $x->{fit_b};
        my $png = "$outdir/${printid}_${tag}.png";
        my $vg_end = $x->{vg}[ $x->{maxrow} + 3 ] // $x->{vg}[-1];
        _run_gnuplot(<<"GP") and push @png, $png;
set terminal $term
set output "$png"
set title "Vt Extraction $lbl (Vt=${\ sprintf('%.2f',$vt)} V) - $title"
set xlabel "VGS (V)"; set ylabel "sqrt(IDS) (A^0.5)"
set grid; set key top left
f(x) = $m*x + $b
plot "$dd" u 1:2 w l lw 2 t "sqrt(IDS)", \\
     [$vt:$vg_end] f(x) w l lw 2 dt 2 t "tangent @ max slope"
GP
    }

    # 4. Output curves IDS-VDS family (one line per VGS group, blue->red gradient).
    {
        my $vds = $res->{_vds};
        my @files;
        my $ng = $vds->{groups};
        for my $g (0 .. $ng - 1) {
            my $vgs = $vds->{vg}[$g][0];
            my $f = _datafile($tmp, "vds$g", $vds->{vd}[$g], $vds->{id}[$g]);
            my $frac = $ng > 1 ? $g / ($ng - 1) : 0;
            my $rgb = sprintf("#%02x%02x%02x",
                int(40 + 215 * $frac), 40, int(215 * (1 - $frac) + 40));
            push @files, qq{"$f" u 1:2 w l lw 1.6 lc rgb "$rgb" t "VG=$vgs"};
        }
        my $png = "$outdir/${printid}_IDS.png";
        my $plt = join(", ", @files);
        _run_gnuplot(<<"GP") and push @png, $png;
set terminal $term
set output "$png"
set title "Output Curves IDS-VDS - $title"
set xlabel "VDS (V)"; set ylabel "IDS (A)"
set grid; set key outside right
plot $plt
GP
    }

    # 5. Gate current vs VGS (biased, at VD=10).
    {
        my $f = _datafile($tmp, 'ig', $res->{_fwd}{vg}, [ map { abs($_) } @{ $res->{_fwd}{ig10} } ]);
        my $png = "$outdir/${printid}_IG_Biased.png";
        _run_gnuplot(<<"GP") and push @png, $png;
set terminal $term
set output "$png"
set title "Biased Gate Current - $title"
set xlabel "VGS (V)"; set ylabel "|IG| (A)"
set logscale y; set grid
plot "$f" u 1:2 w l lw 2 t "|IG| @ VD=10V"
GP
    }

    # 6. Contact resistance: R vs 1/(VG-Vt) with the R_Inf extrapolation.
    {
        my $rf = $res->{_Rfit};
        if (@{ $rf->{x} }) {
            my $f = _datafile($tmp, 'rinf', $rf->{x}, $rf->{y});
            my $png = "$outdir/${printid}_Rinf.png";
            my $rinf = $rf->{rinf};
            # slope of the R vs 1/(VG-Vt) line for the trend
            my ($sl, $ic) = TFTAnalysis::linreg($rf->{x}, $rf->{y});
            _run_gnuplot(<<"GP") and push @png, $png;
set terminal $term
set output "$png"
set title "Contact Resistance (R_Inf=${\ sprintf('%.3g',$rinf)} ohm) - $title"
set xlabel "1/(VG-Vt) (1/V)"; set ylabel "R (ohm)"
set grid; set key top left
g(x) = $sl*x + $ic
plot "$f" u 1:2 w p pt 7 ps 1.5 t "R", g(x) w l lw 2 dt 2 t "fit -> R_Inf"
GP
        }
    }

    # 7. Hysteresis: forward vs reverse transfer (10V), semilog.
    {
        my $ff = _datafile($tmp, 'hf', $x10->{vg}, _pos($x10->{ids}));
        my $fr = _datafile($tmp, 'hr', $xr->{vg},  _pos($xr->{ids}));
        my $png = "$outdir/${printid}_Hysteresis.png";
        _run_gnuplot(<<"GP") and push @png, $png;
set terminal $term
set output "$png"
set title "Hysteresis (dVGS=${\ sprintf('%.3f',$res->{Hysteresis_S})} V) - $title"
set xlabel "VGS (V)"; set ylabel "IDS (A)"
set logscale y; set grid; set key top left
plot "$ff" u 1:2 w l lw 2 t "forward", "$fr" u 1:2 w l lw 2 t "reverse"
GP
    }

    return @png;
}

1;
