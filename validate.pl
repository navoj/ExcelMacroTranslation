#!/usr/bin/env perl
# validate.pl - Compare TFTAnalysis output against the Excel-produced Summary.
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use TFTAnalysis;
use JSON::PP qw(decode_json);

my $wafer_dir = shift || "$FindBin::Bin/t/E1538-001/Wafer_1";
my $gt_file   = shift || '/tmp/amx/ground_truth.json';

my $gt = decode_json(do { open my $fh, '<', $gt_file or die $!; local $/; <$fh> });

# Map Excel header -> our key names.
my %H2K = (
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
my @order = @{ $gt->{header} };

# Index ground-truth rows by "UID@Site".
my %gtrow;
for my $row (@{ $gt->{rows} }) {
    $gtrow{ "$row->{UID}\@$row->{Site}" } = $row;
}

sub find_files {
    my ($dir, $uid, $site) = @_;
    my %f;
    opendir(my $dh, $dir) or die "opendir $dir: $!";
    for my $name (readdir $dh) {
        next unless $name =~ /^hf_ids_/;
        next unless $name =~ /_\Q$uid\E\@\Q$site\E_/;
        my $g = "$dir/$name";
        if    ($name =~ /ids_vgs-rev/) { $f{rev} = $g }
        elsif ($name =~ /ids_vgs/)     { $f{fwd} = $g }
        elsif ($name =~ /ids_vds/)     { $f{vds} = $g }
    }
    closedir $dh;
    return \%f;
}

printf "%-10s %-14s %12s %12s %8s\n", 'device', 'param', 'computed', 'expected', '%err';
print '-' x 60, "\n";

my (%sum_err, %cnt_err);
for my $key (sort keys %gtrow) {
    my $g = $gtrow{$key};
    my ($uid, $site) = split /\@/, $key;
    my $f = find_files($wafer_dir, $uid, $site);
    unless ($f->{fwd} && $f->{rev} && $f->{vds}) {
        warn "missing files for $key\n"; next;
    }
    my ($wl) = $g->{'Device ID'} =~ /_(\d+)_(\d+)/ ? ($1, $2) : ();
    my ($w, $l) = $g->{'Device ID'} =~ /_(\d+)_(\d+)/;
    my $res = TFTAnalysis::analyze_device(
        fwd => TFTAnalysis::read_vgs_fwd($f->{fwd}),
        rev => TFTAnalysis::read_vgs_rev($f->{rev}),
        vds => TFTAnalysis::read_vds($f->{vds}),
        w => $w, l => $l,
    );
    for my $hdr (@order) {
        next unless $H2K{$hdr};
        my $k = $H2K{$hdr};
        my $exp = $g->{$hdr};
        my $got = $res->{$k};
        next unless defined $exp && defined $got;
        my $err = (abs($exp) > 1e-30) ? abs(($got - $exp) / $exp) * 100 : abs($got - $exp);
        $sum_err{$hdr} += $err; $cnt_err{$hdr}++;
        printf "%-10s %-14s %12.4g %12.4g %7.1f%%\n", "$uid\@$site", $hdr, $got, $exp, $err;
    }
    print "\n";
}

print "=== Mean abs % error by parameter ===\n";
for my $hdr (@order) {
    next unless $cnt_err{$hdr};
    printf "  %-16s %8.2f%%\n", $hdr, $sum_err{$hdr} / $cnt_err{$hdr};
}
