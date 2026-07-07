#!/usr/bin/env perl
#
# process_tft.pl - Command-line port of the Excel "ProcessTFTAuto" macro.
#
# Discovers autoprobe TFT measurement files under a lot/wafer directory tree,
# runs the AnalysisMaster calculations (TFTAnalysis.pm), writes a parameter
# Summary (CSV + XLSX) and renders the per-device diagnostic charts
# (TFTReport.pm / gnuplot).
#
# Usage:
#   process_tft.pl --lot DIR [--wafer W]... [options]
#   process_tft.pl -c config.json
#
# Options:
#   --lot DIR        Path to the lot directory (contains Wafer_* subdirs), or a
#                    single wafer directory holding hf_ids_* files.
#   --wafer NAME     Wafer subdirectory to process (repeatable). Default: all
#                    Wafer_* subdirectories found (or the --lot dir itself).
#   --out DIR        Output directory for the Summary (default: the wafer dir).
#   --eps VALUE      Gate-dielectric relative permittivity (default 3.9, SiO2).
#   --tox VALUE      Gate-dielectric thickness in angstrom (default 2000).
#   --no-charts      Skip chart generation.
#   --config FILE    Read options from a JSON config file.
#
use strict;
use warnings;
use feature qw(say);
use FindBin;
use lib $FindBin::Bin;
use Getopt::Long;
use File::Basename qw(basename);
use File::Path qw(make_path);
use POSIX qw(strftime);
use TFTAnalysis;
use TFTReport;

my %opt = (eps => 3.9, tox => 2000, charts => 1);
my @wafers;
my $config;
GetOptions(
    'lot=s'      => \$opt{lot},
    'wafer=s'    => \@wafers,
    'out=s'      => \$opt{out},
    'eps=f'      => \$opt{eps},
    'tox=f'      => \$opt{tox},
    'charts!'    => \$opt{charts},
    'config|c=s' => \$config,
) or die "See --help / header for usage.\n";

# Optional JSON config (data_dir, wafers, eps, tox, charts).
if ($config) {
    require JSON::PP;
    open my $fh, '<', $config or die "config $config: $!";
    my $cfg = JSON::PP::decode_json(do { local $/; <$fh> });
    $opt{lot}    //= $cfg->{data_dir} // $cfg->{lot};
    $opt{eps}    = $cfg->{eps} if defined $cfg->{eps};
    $opt{tox}    = $cfg->{tox} if defined $cfg->{tox};
    $opt{charts} = $cfg->{charts} if defined $cfg->{charts};
    @wafers      = @{ $cfg->{wafers} } if $cfg->{wafers};
}

$opt{lot} or die "No lot directory given (use --lot DIR or -c config.json).\n";
-d $opt{lot} or die "Lot directory not found: $opt{lot}\n";

# Determine the list of wafer directories to process.
my @wdirs;
if (@wafers) {
    @wdirs = map { "$opt{lot}/$_" } @wafers;
}
elsif (my @sub = _subdirs($opt{lot}, qr/^Wafer_/i)) {
    @wdirs = @sub;
}
else {
    @wdirs = ($opt{lot});    # the lot dir itself holds the data files
}

for my $wdir (@wdirs) {
    -d $wdir or do { warn "skip (not found): $wdir\n"; next };
    process_wafer($wdir);
}

# ---------------------------------------------------------------------------

sub process_wafer {
    my ($wdir) = @_;
    my $outdir = $opt{out} || $wdir;
    make_path($outdir) unless -d $outdir;

    my @devices = discover_devices($wdir);
    unless (@devices) { warn "no TFT device files in $wdir\n"; return; }
    say sprintf("Processing %s: %d device(s)", $wdir, scalar @devices);

    my @rows;
    for my $dev (sort { $a->{UID} cmp $b->{UID} or $a->{Site} cmp $b->{Site} } @devices) {
        my $res = eval {
            TFTAnalysis::analyze_device(
                fwd => TFTAnalysis::read_vgs_fwd($dev->{fwd}),
                rev => TFTAnalysis::read_vgs_rev($dev->{rev}),
                vds => TFTAnalysis::read_vds($dev->{vds}),
                w   => $dev->{W}, l => $dev->{L},
                eps => $opt{eps}, tox => $opt{tox},
            );
        };
        if (!$res) { warn "  FAILED $dev->{UID}\@$dev->{Site}: $@"; next; }

        my $tdate = (stat $dev->{fwd})[9];
        $dev->{TestDate} = strftime('%Y-%m-%d %H:%M:%S', localtime $tdate);
        $dev->{res} = $res;
        push @rows, TFTReport::summary_row($dev);

        say sprintf("  %-8s\@%-3s  Vt=%.2f gm=%.2e mu_sat=%.2f On/Off=%.2e",
            $dev->{UID}, $dev->{Site}, $res->{Vt}, $res->{gm},
            $res->{SatMobility}, $res->{On_Off_20x0});

        if ($opt{charts}) {
            my $printid = "UID$dev->{UID}\@$dev->{Site}";
            my @png = TFTReport::generate_charts($res, "$outdir/charts", $printid);
            say sprintf("      %d chart(s)", scalar @png) if @png;
        }
    }

    my ($lot, $wafer) = ($devices[0]{Lot}, $devices[0]{Wafer});
    my $base = defined $lot ? "${lot}_Wafer_${wafer}_Summary" : 'Summary';
    my $csv = TFTReport::write_summary_csv("$outdir/$base.csv", \@rows);
    say "  wrote $csv";
    my $xlsx = TFTReport::write_summary_xlsx("$outdir/$base.xlsx", \@rows);
    say "  wrote $xlsx" if $xlsx;
}

# Find hf_ids_vgs_* files and pair each with its -rev and vds partners.
sub discover_devices {
    my ($dir) = @_;
    my @dev;
    opendir(my $dh, $dir) or die "opendir $dir: $!";
    my @names = readdir $dh;
    closedir $dh;
    for my $name (@names) {
        next unless $name =~ /^hf_ids_vgs_/ && $name !~ /-rev/;
        my $meta = parse_name($name) or next;
        my $rev = $name; $rev =~ s/ids_vgs_/ids_vgs-rev_/;
        my $vds = $name; $vds =~ s/ids_vgs_/ids_vds_/;
        next unless -f "$dir/$rev" && -f "$dir/$vds";
        push @dev, {
            %$meta,
            fwd => "$dir/$name", rev => "$dir/$rev", vds => "$dir/$vds",
        };
    }
    return @dev;
}

# Parse a measurement filename into device metadata.
#   hf_ids_vgs_multitest_TFT_96_9_X0_Y5@TL_Wafer_1_E1538-001
# The device ID ends in _<W>_<L>; the UID is the two tokens before the "@site".
sub parse_name {
    my ($name) = @_;
    my ($pre, $site, $wafer, $lot) =
        $name =~ /^hf_ids_vgs_(.+?)\@([^_]+)_Wafer_(\w+)_(\S+?)(?:\.\w+)?$/;
    return undef unless defined $pre && defined $site;
    $pre =~ s/^(?:multitest_|singletest_)//;    # drop test-type prefix
    my @tok = split /_/, $pre;
    return undef if @tok < 3;
    my $uid = join('_', splice(@tok, -2));       # e.g. X0_Y5
    my $dev = join('_', @tok);                    # e.g. TFT_96_9
    my ($w, $l) = $dev =~ /(\d+)_(\d+)$/;
    return undef unless defined $w;
    return {
        DeviceID => $dev, UID => $uid, Site => $site,
        Wafer => $wafer, Lot => $lot, W => $w, L => $l,
    };
}

sub _subdirs {
    my ($dir, $re) = @_;
    opendir(my $dh, $dir) or return ();
    my @d = grep { -d $_ } map { "$dir/$_" }
            grep { !/^\./ && (!$re || /$re/) } readdir $dh;
    closedir $dh;
    return sort @d;
}
