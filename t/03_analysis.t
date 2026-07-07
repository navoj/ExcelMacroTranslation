#!/usr/bin/env perl
#
# 03_analysis.t - Validate the TFTAnalysis port against the reference values
# produced by the Excel AnalysisMaster (stored in a device's Summary sheet).
# The expected numbers below were read from
#   t/E1538-001/Wafer_1/E1538-001_Wafer_1_Summary.xls
# for two representative devices, and cover the parameters that the Excel
# formulas compute deterministically.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/..";
use TFTAnalysis;

my $wdir = "$FindBin::Bin/E1538-001/Wafer_1";

# Expected values (from the Excel Summary) keyed by "UID@Site" then parameter.
my %expect = (
    'X0_Y5@TL' => {
        Vt => 7.3487, gm => 1.8704e-6, SatMobility => 5.6114,
        'Mobility_0.5' => 9.4394, 'Mobility_0.2' => 9.6482, 'Mobility_0.1' => 14.712,
        Vt_10 => 2.8893, gm_10 => 1.6925e-5, On_Off_20x0 => 2.0175e7,
        IG_N5 => 4.20411e-12, IG_20 => 3.41144e-11,
        Lambda_20 => -5.6846, Lambda_15 => -8.0954, Lambda_10 => -17.334,
        Idrive => 1.49026e-4, VD_Resistance => 58303.85, R_Inf => 59010.9,
        Ireverse => 7.405012e-12,
    },
    'X1_Y5@TR' => {
        Vt => 6.4711, gm => 1.8867e-6, SatMobility => 5.7099,
        'Mobility_0.5' => 9.0113, 'Mobility_0.2' => 9.0959,
        Vt_10 => 2.5610, gm_10 => 1.74521e-5, On_Off_20x0 => 2.1205e7,
        IG_N5 => 8.76215e-12, Lambda_20 => -7.5941,
        VD_Resistance => 53776.3, R_Inf => 54821.1,
    },
);

sub find_files {
    my ($uid, $site) = @_;
    opendir(my $dh, $wdir) or die "opendir $wdir: $!";
    my %f;
    for my $n (readdir $dh) {
        next unless $n =~ /^hf_ids_/ && $n =~ /_\Q$uid\E\@\Q$site\E_/;
        if    ($n =~ /ids_vgs-rev/) { $f{rev} = "$wdir/$n" }
        elsif ($n =~ /ids_vgs/)     { $f{fwd} = "$wdir/$n" }
        elsif ($n =~ /ids_vds/)     { $f{vds} = "$wdir/$n" }
    }
    closedir $dh;
    return \%f;
}

for my $dev (sort keys %expect) {
    my ($uid, $site) = split /\@/, $dev;
    my $f = find_files($uid, $site);
    SKIP: {
        skip "missing data for $dev", scalar keys %{ $expect{$dev} }
            unless $f->{fwd} && $f->{rev} && $f->{vds};
        my $res = TFTAnalysis::analyze_device(
            fwd => TFTAnalysis::read_vgs_fwd($f->{fwd}),
            rev => TFTAnalysis::read_vgs_rev($f->{rev}),
            vds => TFTAnalysis::read_vds($f->{vds}),
            w => 96, l => 9, eps => 3.9, tox => 2000,
        );
        for my $p (sort keys %{ $expect{$dev} }) {
            my $exp = $expect{$dev}{$p};
            my $got = $res->{$p};
            my $tol = 0.03 * abs($exp);    # 3% tolerance
            ok(abs($got - $exp) <= $tol, "$dev $p ~ $exp (got $got)")
                or diag(sprintf("  expected %.6g, got %.6g (%.1f%%)",
                    $exp, $got, abs($exp) > 0 ? abs(($got - $exp) / $exp) * 100 : 0));
        }
    }
}

done_testing();
