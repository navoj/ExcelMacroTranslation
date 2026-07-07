package TFTAnalysis;

# TFTAnalysis.pm
#
# Perl port of the Excel "AnalysisMaster_Autoprobe_Prod" worksheet
# calculations and the "ProcessTFTAuto" VBA macro used by the FEDC test group
# to characterize thin-film transistors (TFTs) from autoprobe sweep data.
#
# Each raw device measurement consists of three tab-delimited files:
#   hf_ids_vgs_*      forward transfer sweep, two VD groups (VD=1 and VD=10)
#   hf_ids_vgs-rev_*  reverse transfer sweep at VD=10
#   hf_ids_vds_*      output curves, 11 VGS groups (-5..20 V)
#
# The module reproduces the spreadsheet pipeline:
#   raw -> cubic midpoint interpolation -> centered moving-average smoothing
#       -> parameter extraction (Vt, gm, subthreshold slope, mobility, ...).
#
# The public entry point is analyze_device(); it returns a hash of the 29
# summary parameters that the Excel "Summary" sheet reports.

use strict;
use warnings;
use POSIX qw(floor);

our $VERSION = '1.0';

# ---- Physical constants (Excel "Supplied Data" sheet) ----------------------
# The gate-dielectric constants depend on which AnalysisMaster a lot was
# processed with.  They are package variables so a driver can set them per lot
# (e.g. from config).  Defaults match the SiO2 autoprobe master used for the
# bundled E1538 test data (tox=2000 A, epsilon=3.9).
our $EPS0 = 8.85418e-12;    # permittivity of free space [F/m]   (Supplied B15)
our $EPS  = 3.9;            # gate dielectric rel. permittivity  (Supplied B2)
our $TOX  = 2000;           # gate dielectric thickness [angstrom] (Supplied B1)

# Interpolation used for the IDS-VGS transfer sweeps: 'linear' (SiO2 master,
# used for the bundled test data) or 'cubic' (later masters).  The IDS-VDS
# output curves always use the cubic estimator.
our $TRANSFER_INTERP = 'linear';

# C0 in F/cm^2  (Supplied Data D3 = B15*B2/B1*1e6)
sub c0_cm2 { $EPS0 * $EPS / $TOX * 1e6 }
# C0 in F/um^2 (Supplied Data B3 = B15*B2/B1/100)
sub c0_um2 { $EPS0 * $EPS / $TOX / 100 }

# ===========================================================================
# Numeric helpers
# ===========================================================================

# Ordinary least squares straight-line fit; returns ($slope, $intercept).
# Equivalent to Excel LINEST(y, x) / SLOPE()+INTERCEPT().
sub linreg {
    my ($x, $y) = @_;
    my $n = scalar @$x;
    return (0, 0) if $n < 2;
    my ($sx, $sy, $sxx, $sxy) = (0, 0, 0, 0);
    for my $i (0 .. $n - 1) {
        $sx  += $x->[$i];
        $sy  += $y->[$i];
        $sxx += $x->[$i] * $x->[$i];
        $sxy += $x->[$i] * $y->[$i];
    }
    my $den = $n * $sxx - $sx * $sx;
    return (0, $sy / $n) if $den == 0;
    my $slope = ($n * $sxy - $sx * $sy) / $den;
    my $intercept = ($sy - $slope * $sx) / $n;
    return ($slope, $intercept);
}

# Polynomial least squares fit of degree $deg (with intercept).
# Returns coefficients [b0, b1, ..., b_deg] where y = b0 + b1*x + ... .
# Used for the Excel LINEST(y, x^{1,2,3}) "Moyer" cubic fits.
sub polyfit {
    my ($x, $y, $deg) = @_;
    my $n = scalar @$x;
    my $m = $deg + 1;
    # Build normal equations A c = b with A[j][k] = sum x^(j+k), b[j]=sum y*x^j
    my @A = map { [ (0) x $m ] } 1 .. $m;
    my @b = (0) x $m;
    for my $i (0 .. $n - 1) {
        my @pw = (1);
        push @pw, $pw[-1] * $x->[$i] for 1 .. 2 * $deg;
        for my $j (0 .. $deg) {
            $b[$j] += $y->[$i] * $pw[$j];
            $A[$j][$_] += $pw[$j + $_] for 0 .. $deg;
        }
    }
    return _gauss(\@A, \@b);
}

# Solve a small dense linear system by Gaussian elimination with partial pivot.
sub _gauss {
    my ($A, $b) = @_;
    my $n = scalar @$b;
    my @M = map { [ @{ $A->[$_] }, $b->[$_] ] } 0 .. $n - 1;
    for my $col (0 .. $n - 1) {
        my $piv = $col;
        for my $r ($col + 1 .. $n - 1) {
            $piv = $r if abs($M[$r][$col]) > abs($M[$piv][$col]);
        }
        @M[$col, $piv] = @M[$piv, $col];
        my $d = $M[$col][$col];
        return (0) x $n if $d == 0;
        for my $r (0 .. $n - 1) {
            next if $r == $col;
            my $f = $M[$r][$col] / $d;
            $M[$r][$_] -= $f * $M[$col][$_] for $col .. $n;
        }
    }
    return map { $M[$_][$n] / $M[$_][$_] } 0 .. $n - 1;
}

# Excel MATCH(lookup, ascending_array, 1): index (0-based) of the largest
# element that is <= lookup. Clamps to 0 when lookup precedes the first value.
sub match_le {
    my ($arr, $v) = @_;
    my $idx = 0;
    for my $i (0 .. $#$arr) {
        last if $arr->[$i] > $v;
        $idx = $i;
    }
    return $idx;
}

# Centered moving average of half-width $r, clipped at the array ends.
# Reproduces the spreadsheet SUM(range)/count smoothing columns.
sub smooth_centered {
    my ($x, $r) = @_;
    my $n = scalar @$x;
    my @out;
    for my $i (0 .. $n - 1) {
        my $lo = $i - $r; $lo = 0 if $lo < 0;
        my $hi = $i + $r; $hi = $n - 1 if $hi > $n - 1;
        my $s = 0;
        $s += $x->[$_] for $lo .. $hi;
        push @out, $s / ($hi - $lo + 1);
    }
    return \@out;
}

# ===========================================================================
# Interpolation  (Excel "Interpolated VGS/VDS" sheets)
# Doubles the sample density: original points on even output rows, midpoints
# on odd rows.  Voltage midpoints are linear; current midpoints use a 4-point
# cubic estimator, with dedicated boundary formulas at each end.
# ===========================================================================

sub interp_voltage {
    my ($d) = @_;
    my $n = scalar @$d;
    my @o;
    for my $k (0 .. $n - 1) {
        push @o, $d->[$k];
        push @o, ($d->[$k] + $d->[$k + 1]) / 2 if $k < $n - 1;
    }
    return \@o;
}

sub interp_current {
    my ($d) = @_;
    my $n = scalar @$d;
    return [ @$d ] if $n < 2;
    return [ $d->[0], ($d->[0] + $d->[1]) / 2, $d->[1] ] if $n < 5;
    my @o = (0) x (2 * $n - 1);
    $o[ 2 * $_ ] = $d->[$_] for 0 .. $n - 1;      # data on even output rows
    # interior 4-point cubic midpoints: (-d[k-1] + 9 d[k] + 9 d[k+1] - d[k+2])/16
    for my $k (1 .. $n - 3) {
        $o[ 2 * $k + 1 ] =
            (-$d->[$k - 1] + 9 * $d->[$k] + 9 * $d->[$k + 1] - $d->[$k + 2]) / 16;
    }
    # First midpoint boundary references the neighbouring cubic midpoints
    # (Excel "Interpolated VDS" B3 = -(9*B9 -17*B7 -33*B5 -39*B2)/80).
    $o[1] = (39 * $o[0] + 33 * $o[3] + 17 * $o[5] - 9 * $o[7]) / 80;
    # Last midpoint boundary (symmetric, data-point form).
    $o[ 2 * $n - 3 ] =
        (39 * $d->[$n - 1] + 33 * $d->[$n - 2] + 17 * $d->[$n - 3] - 9 * $d->[$n - 4]) / 80;
    return \@o;
}

# Linear-midpoint interpolation.  The SiO2 autoprobe master interpolates the
# IDS-VGS transfer sweeps linearly (Excel "Interpolated VGS" B3 = (B2+B4)/2),
# reserving the cubic estimator above for the smoother IDS-VDS output curves.
sub interp_current_linear {
    my ($d) = @_;
    my $n = scalar @$d;
    my @o;
    for my $k (0 .. $n - 1) {
        push @o, $d->[$k];
        push @o, ($d->[$k] + $d->[$k + 1]) / 2 if $k < $n - 1;
    }
    return \@o;
}

# ===========================================================================
# Raw file readers
# ===========================================================================

sub _split_row {
    my $line = shift;
    $line =~ s/\r?\n$//;
    my @t = split /\t/, $line;
    return @t;
}

# Forward transfer: columns [VD ID VG IG] x2 groups (VD=1, VD=10).
sub read_vgs_fwd {
    my ($path) = @_;
    open my $fh, '<', $path or die "read_vgs_fwd $path: $!";
    <$fh>;    # header
    my (@vg, @id1, @ig1, @id10, @ig10);
    while (my $line = <$fh>) {
        next if $line =~ /^\s*$/;
        my @t = _split_row($line);
        push @id1,  $t[1] + 0;
        push @vg,   $t[2] + 0;
        push @ig1,  $t[3] + 0;
        push @id10, $t[5] + 0;
        push @ig10, $t[7] + 0;
    }
    close $fh;
    return { vg => \@vg, id1 => \@id1, ig1 => \@ig1, id10 => \@id10, ig10 => \@ig10 };
}

# Reverse transfer: columns [VD ID VG IG], single group at VD=10.
# Sorted ascending by VGS (the VBA sorts "Linked Reverse Data" before use).
sub read_vgs_rev {
    my ($path) = @_;
    open my $fh, '<', $path or die "read_vgs_rev $path: $!";
    <$fh>;
    my @rows;
    while (my $line = <$fh>) {
        next if $line =~ /^\s*$/;
        my @t = _split_row($line);
        push @rows, [ $t[2] + 0, $t[1] + 0, $t[3] + 0 ];    # vg, id, ig
    }
    close $fh;
    @rows = sort { $a->[0] <=> $b->[0] } @rows;
    return {
        vg => [ map { $_->[0] } @rows ],
        id => [ map { $_->[1] } @rows ],
        ig => [ map { $_->[2] } @rows ],
    };
}

# Output curves: columns [VG IG VD ID] x N groups (11 VGS values).
sub read_vds {
    my ($path) = @_;
    open my $fh, '<', $path or die "read_vds $path: $!";
    my $hdr = <$fh>;
    my @cols = _split_row($hdr);
    my $groups = int(scalar(@cols) / 4);
    my (@vg, @ig, @vd, @id);
    for (0 .. $groups - 1) { push @vg, []; push @ig, []; push @vd, []; push @id, []; }
    while (my $line = <$fh>) {
        next if $line =~ /^\s*$/;
        my @t = _split_row($line);
        for my $g (0 .. $groups - 1) {
            my $b = $g * 4;
            push @{ $vg[$g] }, $t[$b] + 0;
            push @{ $ig[$g] }, $t[$b + 1] + 0;
            push @{ $vd[$g] }, $t[$b + 2] + 0;
            push @{ $id[$g] }, $t[$b + 3] + 0;
        }
    }
    close $fh;
    return { groups => $groups, vg => \@vg, ig => \@ig, vd => \@vd, id => \@id };
}

# ===========================================================================
# Transfer-curve parameter extraction engine
#
# Implements the shared logic of the "Sorted VGS Data", "HV Vt Extract" and
# "Reverse Vt Extract" worksheets.  Given a raw transfer sweep (VGS + IDS at
# one VD) it interpolates, smooths, and extracts Vt, gm, subthreshold slope
# and (in saturation) the field-effect mobility.
#
# Arguments (hash ref):
#   vg_raw, id_raw : raw sweep arrays
#   w, l           : device width/length [um]
#   saturation     : true for the VD=10 sweep (compute mobility, wider window)
#
# Returns a hash of extracted values plus intermediate arrays for plotting.
# ===========================================================================
sub extract_transfer {
    my (%a) = @_;
    my $vg = interp_voltage($a{vg_raw});
    my $id_i = ($TRANSFER_INTERP eq 'cubic')
        ? interp_current($a{id_raw})
        : interp_current_linear($a{id_raw});
    my $n = scalar @$vg;

    my $ids = smooth_centered($id_i, 2);            # 5-pt centered MA (col B/C)

    # sqrt(IDS) and its local slope (cols F, G)
    my @sq = map { my $v = $_; sqrt($v > 0 ? $v : 0) } @$ids;
    my @slope = (0);
    for my $i (1 .. $n - 1) {
        push @slope, ($ids->[$i - 1] < 1e-12 ? 0 : $sq[$i] - $sq[$i - 1]);
    }

    # Max slope of sqrt(IDS), searched over a restricted VGS window
    # (Excel rows 102..318 -> 0-based indices 100..316).
    my ($lo, $hi) = (100, $n - 1 < 316 ? $n - 1 : 316);
    my $smax = -9e99;
    $smax = $slope[$_] > $smax ? $slope[$_] : $smax for $lo .. $hi;
    my $mrow = $lo;
    for my $i (1 .. $hi) { if ($slope[$i] == $smax) { $mrow = $i; last } }

    # Straight-line fit of sqrt(IDS) vs VGS on 9 points around the max slope
    # (offsets -5..+3), then Vt = -intercept/slope.
    my (@fx, @fy);
    for my $off (-5 .. 3) {
        my $idx = $mrow + $off;
        next if $idx < 0 || $idx > $n - 1;
        push @fx, $vg->[$idx];
        push @fy, $sq[$idx];
    }
    my ($m, $b) = linreg(\@fx, \@fy);
    my $vt = $m != 0 ? -$b / $m : 0;

    # Transconductance: gm = max of the 7-pt-smoothed local derivative.
    my @gmraw = (0);
    for my $i (1 .. $n - 1) {
        my $dv = $vg->[$i] - $vg->[$i - 1];
        my $g = $dv != 0 ? ($ids->[$i] - $ids->[$i - 1]) / $dv : 0;
        push @gmraw, ($g > 0 ? $g : 0);
    }
    my $gms = smooth_centered(\@gmraw, 3);
    my $ghi = $n - 1 < 316 ? $n - 1 : 316;
    my $gm = 0;
    $gm = $gms->[$_] > $gm ? $gms->[$_] : $gm for 0 .. $ghi;

    # Saturation field-effect mobility  = 2*m^2*L/(W*C0)   [cm^2/V-s]
    my $satmob;
    if ($a{saturation}) {
        $satmob = 2 * $m * $m * $a{l} / ($a{w} * c0_cm2());
    }

    # Subthreshold slope: fit log10(IDS) vs VGS between current limits set by
    # the point of steepest log-slope.
    my @logi = map { $_ > 0 ? log($_) / log(10) : undef } @$ids;
    my @pslope = (0);
    for my $i (1 .. $n - 1) {
        push @pslope,
            ((defined $logi[$i] && defined $logi[$i - 1]) ? $logi[$i] - $logi[$i - 1] : 0);
    }
    my $qs = smooth_centered(\@pslope, 2);
    my $qlo = $a{saturation} ? 100 : 144;           # rows 102 / 146
    my $qhi = $n - 1;
    my $qmax = -9e99;
    $qmax = $qs->[$_] > $qmax ? $qs->[$_] : $qmax for $qlo .. $qhi;
    my $qrow = $qlo;
    for my $i (1 .. $qhi) { if ($qs->[$i] == $qmax) { $qrow = $i; last } }
    my $icur = $ids->[$qrow];                        # current at max slope

    # Fit window between IDS = icur/2 and IDS = icur*10 (searched over rows 82+)
    my @sub = @{$ids}[80 .. ($n - 1)];
    my $ll = 80 + match_le(\@sub, $icur / 2);
    my $ul = 80 + match_le(\@sub, $icur * 10);
    my (@sx, @sy);
    for my $i ($ll .. $ul) {
        next unless defined $logi[$i];
        push @sx, $vg->[$i];
        push @sy, $logi[$i];
    }
    my ($tm) = linreg(\@sx, \@sy);
    my $subth = $tm != 0 ? 1 / $tm : 0;

    return {
        vt => $vt, gm => $gm, subth => $subth, satmob => $satmob,
        slope_m => $m, maxrow => $mrow,
        upper_vgs => $vg->[$ul], upper_ids => $ids->[$ul],
        vg => $vg, ids => $ids, sqrt_ids => \@sq, logi => \@logi,
        fit_x => \@fx, fit_m => $m, fit_b => $b,
    };
}

# Moyer contact-resistance analysis.
#
# Fits a cubic to the low-VDS region of each output curve, evaluates the fitted
# current W and its slope X on a fine VDS grid, and reads the drain offset
# voltage / resistance / intercept at the 15%-of-max-current point.  Following
# the spreadsheet, the resistance is always taken from the VGS=20 slope curve,
# sampled at the point where each curve reaches 15% of its own maximum current.

# Cubic fit (b0 + b1 v + b2 v^2 + b3 v^3) over VDS in [0, VDS(20%-of-max)].
sub _moyer_fit {
    my ($vd, $id) = @_;
    my $imax = 0;
    $imax = $id->[$_] > $imax ? $id->[$_] : $imax for 0 .. $#$id;
    return ([ 0, 0, 0, 0 ], $imax) if $imax <= 0;
    my $j20 = match_le($id, $imax / 5);
    $j20 = 3 if $j20 < 3;
    my @c = polyfit([ @{$vd}[0 .. $j20] ], [ @{$id}[0 .. $j20] ], 3);
    return (\@c, $imax);
}

# Fine VDS grid V = 0..5 step 0.01 (Excel column V, rows 2..502).
sub _fine_grid { my @v; push @v, $_ * 0.01 for 0 .. 500; return \@v; }

# Evaluate cubic value and slope at a scalar v.
sub _cubic_val   { my ($c, $v) = @_; $c->[0] + $c->[1] * $v + $c->[2] * $v**2 + $c->[3] * $v**3 }
sub _cubic_slope { my ($c, $v) = @_; $c->[1] + 2 * $c->[2] * $v + 3 * $c->[3] * $v**2 }

# ===========================================================================
# Full device analysis -> the 29 Summary parameters
# ===========================================================================
sub analyze_device {
    my (%a) = @_;
    local $EPS = defined $a{eps} ? $a{eps} : $EPS;
    local $TOX = defined $a{tox} ? $a{tox} : $TOX;
    local $TRANSFER_INTERP = defined $a{transfer_interp} ? $a{transfer_interp} : $TRANSFER_INTERP;
    my ($fwd, $rev, $vds) = @a{qw(fwd rev vds)};
    my ($w, $l) = ($a{w}, $a{l});
    my %r;

    # --- Transfer-curve parameters (VD=1 and VD=10) ---
    my $x1 = extract_transfer(vg_raw => $fwd->{vg}, id_raw => $fwd->{id1},
                              w => $w, l => $l, saturation => 0);
    my $x10 = extract_transfer(vg_raw => $fwd->{vg}, id_raw => $fwd->{id10},
                               w => $w, l => $l, saturation => 1);
    @r{qw(Vt gm Subthreshold)}       = ($x1->{vt}, $x1->{gm}, $x1->{subth});
    @r{qw(Vt_10 gm_10 Subthreshold_10 SatMobility)} =
        ($x10->{vt}, $x10->{gm}, $x10->{subth}, $x10->{satmob});

    # --- On/Off, drive, leakage, reverse leakage (smoothed VD=10 curve) ---
    my $c = $x10->{ids};                             # Sorted VGS Data col C
    my $nc = scalar @$c;
    my ($i0, $i20, $l82) = ($c->[160], $c->[$nc - 1], 80);
    my ($omax, $omin, $rmax) = (-9e99, 9e99, -9e99);
    for my $i ($l82 .. $nc - 1) {
        $omax = $c->[$i] if $c->[$i] > $omax;
        $omin = $c->[$i] if $c->[$i] < $omin;
    }
    $rmax = $c->[$_] > $rmax ? $c->[$_] : $rmax for 0 .. $l82;
    $r{On_Off_20x0}   = $i0 != 0 ? $c->[$nc - 1] / $i0 : 0;
    $r{On_Off_20xN15} = $omin != 0 ? $omax / $omin : 0;
    $r{Idrive}   = $omax;
    $r{Ileak}    = $omin;
    $r{Ireverse} = $rmax;

    # --- Gate currents at VDS=0 (from the output-curve file) ---
    # IG_N5 = VGS=-5 group, IG_20 = VGS=+20 group, first (VDS=0) point.
    $r{IG_N5} = $vds->{ig}[0][0];
    $r{IG_20} = $vds->{ig}[ $vds->{groups} - 1 ][0];

    # --- Low-field mobility from the output curves (gd method) ---
    my $vt1 = $x1->{vt};
    my %gd;                                          # gd{vds}{vgs} = IDS/VDS
    my %vdi; my %idi;
    for my $g (0 .. $vds->{groups} - 1) {
        my $vgs = $vds->{vg}[$g][0];
        my $vdI = interp_voltage($vds->{vd}[$g]);
        my $idI = interp_current($vds->{id}[$g]);
        $vdi{$vgs} = $vdI; $idi{$vgs} = $idI;
        # interpolated rows 3,4,7,12 -> indices 1,2,5,10 -> VDS 0.1,0.2,0.5,1.0
        $gd{'0.1'}{$vgs} = $vdI->[1] ? $idI->[1] / $vdI->[1] : 0;
        $gd{'0.2'}{$vgs} = $vdI->[2] ? $idI->[2] / $vdI->[2] : 0;
        $gd{'0.5'}{$vgs} = $vdI->[5] ? $idI->[5] / $vdI->[5] : 0;
    }
    my $mob_const = c0_um2() * $w / $l;
    for my $vd ('0.1', '0.2', '0.5') {
        my (@mx, @my);
        for my $vgs (12.5, 15, 17.5) {
            my $g = $gd{$vd}{$vgs};
            next unless $g;
            push @mx, $vgs - $vt1;
            push @my, ($vgs - $vt1) / $g * $mob_const;   # 1/mu apparent
        }
        my (undef, $inter) = linreg(\@mx, \@my);
        my $mob = $inter != 0 ? 1 / $inter / 1e8 : 0;
        $r{ 'Mobility_' . $vd } = $mob;
    }

    # --- Channel-length modulation (Lambda) = saturation Ids-Vds x-intercept ---
    for my $pair ([10, 'Lambda_10'], [15, 'Lambda_15'], [20, 'Lambda_20']) {
        my ($vgs, $key) = @$pair;
        my $vdI = $vdi{$vgs}; my $idI = $idi{$vgs};
        my (@lx, @ly);
        for my $i (150 .. 200) {                     # VDS 15..20 (rows 152..202)
            last if $i > $#$vdI;
            push @lx, $vdI->[$i];
            push @ly, $idI->[$i];
        }
        my ($sm, $sb) = linreg(\@lx, \@ly);
        $r{$key} = $sm != 0 ? -$sb / $sm : 0;
    }

    # --- Moyer contact resistance (VD_Offset/Resistance/Intercept, R_Inf) ---
    # Build the VGS=20 fitted current (W) and slope (X) on the fine grid.
    my $V = _fine_grid();
    my ($c20, $max20) = _moyer_fit($vdi{20}, $idi{20});
    my @W20 = map { _cubic_val($c20, $_) }   @$V;
    my @X20 = map { _cubic_slope($c20, $_) } @$V;
    my $n58 = match_le(\@W20, $max20 * 0.15);
    $r{VD_Offset}    = $V->[ $n58 - 1 ];
    $r{VD_Resistance} = $X20[ $n58 - 1 ] != 0 ? 1 / $X20[ $n58 - 1 ] : 0;
    $r{VD_Intercept} = $r{VD_Offset} - $W20[$n58] * $r{VD_Resistance};
    # Contact resistance R_Inf: extrapolate resistance vs 1/(VGS-Vt) to infinite
    # gate.  Each VGS's resistance is 1/(VGS=20 slope) at the fine-grid index
    # where that VGS's own fitted current reaches 15% of its own maximum.
    my (@rx, @ry);
    for my $vgs (20, 17.5, 15, 12.5) {
        my ($cV, $maxV) = _moyer_fit($vdi{$vgs}, $idi{$vgs});
        my @WV = map { _cubic_val($cV, $_) } @$V;
        my $j = match_le(\@WV, $maxV * 0.15);
        my $res = $X20[ $j - 1 ] != 0 ? 1 / $X20[ $j - 1 ] : 0;
        push @rx, 1 / ($vgs - $vt1);
        push @ry, $res;
    }
    my (undef, $rinf) = linreg(\@rx, \@ry);
    $r{R_Inf} = $rinf;

    # --- Subthreshold hysteresis (reverse vs forward VGS at matched current) ---
    my $xr = extract_transfer(vg_raw => $rev->{vg}, id_raw => $rev->{id},
                              w => $w, l => $l, saturation => 1);
    $r{Vt_rev} = $xr->{vt};
    my $rids = $xr->{ids};
    my @rsub = @{$rids}[3 .. $#$rids];               # B3:B322 in reverse sheet
    my $rj = 3 + match_le(\@rsub, $x10->{upper_ids});
    my $rev_vgs = $xr->{vg}[$rj];
    $r{Hysteresis_S} = $rev_vgs - $x10->{upper_vgs};

    # Stash intermediate curves so the caller can draw the diagnostic charts.
    $r{_x1} = $x1; $r{_x10} = $x10; $r{_xr} = $xr;
    $r{_vdi} = \%vdi; $r{_idi} = \%idi; $r{_vds} = $vds;
    $r{_fwd} = $fwd; $r{_rev} = $rev; $r{_vt1} = $vt1;
    $r{_Rfit} = { x => \@rx, y => \@ry, rinf => $rinf };
    return \%r;
}

# Ordered list of the summary columns, matching the Excel "Summary" sheet.
our @SUMMARY_COLS = qw(
    Vt gm Subthreshold SatMobility Mobility_0.5 Mobility_0.2 Mobility_0.1
    Lambda_20 Vt_10 gm_10 Subthreshold_10 On_Off_20x0 On_Off_20xN15
    IG_N5 IG_20 Lambda_15 Lambda_10 Idrive Ileak VD_Offset VD_Resistance
    VD_Intercept R_Inf Hysteresis_S Ireverse
);

1;
