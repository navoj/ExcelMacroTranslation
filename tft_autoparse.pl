#!/usr/bin/env perl
use strict;
use warnings;
use feature qw(say);
use JSON::PP qw(decode_json);
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(basename);
use Text::CSV_XS;
use Getopt::Long;
use List::Util qw(sum min max);
use POSIX qw(floor);

# ---------------- CLI / config ----------------
my $config_file = 'config.json';
GetOptions('config|c=s' => \$config_file) or die "Usage: $0 [-c config.json]\n";
-f $config_file or die "Config not found: $config_file\n";
my $cfg = do {
  open my $fh, '<', $config_file or die $!;
  local $/; decode_json(<$fh>);
};
my $data_dir = $cfg->{data_dir} // 'data';
-d $data_dir or die "Data dir not found: $data_dir\n";

# ---------------- Utilities ----------------
sub ensure_dir { my $d = shift; make_path($d) unless -d $d; }
sub abs_path  { File::Spec->rel2abs(shift) }
sub trim      { my $s = shift; $s =~ s/^\s+|\s+$//g; $s }
sub parse_num { my $s = shift; $s =~ s/[^\dEe\+\-\.]//g; $s+0 }

# filename → { lot, wafer, site, kind }
sub parse_meta_from_name {
  my ($fname) = @_;
  my $kind = ($fname =~ /ids_vgs_rev/i) ? 'VGS_REV' :
             ($fname =~ /ids_vgs_/i)    ? 'VGS_FWD' :
             ($fname =~ /ids_vds_/i)    ? 'VDS'     : 'UNKNOWN';
  my ($site)  = $fname =~ /_(\S+?)_Wafer_/i;        # e.g., A@A4
  my ($wafer) = $fname =~ /_Wafer_(\d+)_/i;         # e.g., 3
  my ($lot)   = $fname =~ /_([A-Za-z]\d{4}-\d{3})\.txt$/i; # e.g., E2446-001
  return { lot=>$lot//'Lot', wafer=>$wafer//'W', site=>$site//'Site', kind=>$kind };
}

# CSV writer
sub csv_out {
  my ($path, $rows) = @_;
  ensure_dir( File::Basename::dirname($path) );
  open my $fh, '>', $path or die "Write $path: $!";
  my $w = Text::CSV_XS->new({binary=>1, eol=>"\n"});
  $w->print($fh, $rows->[0]);              # header
  for my $i (1..$#$rows) { $w->print($fh, $rows->[$i]); }
  close $fh;
  say "  wrote $path";
}

# Nearest index in array by x-target
sub nearest_idx {
  my ($xs, $x0) = @_;
  my $best_i = 0; my $best_d = 1e99;
  for my $i (0..$#$xs) {
    my $d = abs($xs->[$i]-$x0);
    if ($d < $best_d) { $best_d=$d; $best_i=$i; }
  }
  return $best_i;
}

# simple derivative
sub deriv {
  my ($x, $y) = @_;
  my @gm;
  for my $i (1..$#$x-0) {
    my $dx = $x->[$i]-$x->[$i-1];
    my $dy = $y->[$i]-$y->[$i-1];
    push @gm, ($dx!=0 ? $dy/$dx : 0);
  }
  return \@gm; # length N-1, at midpoints
}

# Vth by linear extrapolation at gm,max (linear regime)
sub vth_from_linear_extrap {
  my ($vg, $id) = @_;
  return undef if @$vg < 3;
  my $gm = deriv($vg,$id); # length N-1
  my ($imax) = 0; my $gmax = -1e99;
  for my $i (0..$#$gm) { if ($gm->[$i] > $gmax) { $gmax = $gm->[$i]; $imax=$i; } }
  # Use two points around gm,max to fit line Id = a*Vg + b → Vth = -b/a
  my $i1 = $imax; my $i2 = $imax+1; $i2 = $#$vg if $i2 > $#$vg;
  $i1 = 0 if $i1 < 0;
  my $x1 = $vg->[$i1]; my $y1 = $id->[$i1];
  my $x2 = $vg->[$i2]; my $y2 = $id->[$i2];
  my $a = ($x2==$x1) ? undef : ($y2-$y1)/($x2-$x1);
  return undef unless defined $a && $a != 0;
  my $b = $y1 - $a*$x1;
  return (-$b/$a, $gmax);
}

# ---------------- Parsers for your file formats ----------------
# ids_vgs_rev: columns: VD ID VG IG (single sweep)  (from your file)  [2](https://arizonastateu-my.sharepoint.com/personal/jtrujil1_asurite_asu_edu/_layouts/15/download.aspx?UniqueId=5b87835a-b126-445b-9875-0bcfebd30209&Translate=false&tempauth=v1.eyJzaXRlaWQiOiJjZjliNzBmYS0wZjc2LTQxYWUtYjY2Mi05OWY2YmY3Y2RiYzYiLCJhcHBfZGlzcGxheW5hbWUiOiJPZmZpY2UgMzY1IFNlYXJjaCBTZXJ2aWNlIiwiYXBwaWQiOiI2NmE4ODc1Ny0yNThjLTRjNzItODkzYy0zZThiZWQ0ZDY4OTkiLCJhdWQiOiIwMDAwMDAwMy0wMDAwLTBmZjEtY2UwMC0wMDAwMDAwMDAwMDAvYXJpem9uYXN0YXRldS1teS5zaGFyZXBvaW50LmNvbUA0MWY4OGVjYi1jYTYzLTQwNGQtOTdkZC1hYjBhMTY5ZmQxMzgiLCJleHAiOiIxNzU4MTM1NjU1In0.CkAKDGVudHJhX2NsYWltcxIwQ1BycXE4WUdFQUFhRmt4VVZqUk9hVms0VkZVeVRURlhWVkU1YVVKRVFVRXFBQT09CjIKCmFjdG9yYXBwaWQSJDAwMDAwMDAzLTAwMDAtMDAwMC1jMDAwLTAwMDAwMDAwMDAwMAoKCgRzbmlkEgI2NBILCOTjgurFh7s-EAUaDjIwLjE5MC4xMzIuMTA2Kiw5QkVpOG56UFNRVTFaUkJZaWRzTzBZYUtLNm43NnVrNFJ5T0NmWHQ5b1VJPTChATgBQhChxrAwdWAAAOjAlTyp25N4ShBoYXNoZWRwcm9vZnRva2VuUghbImttc2kiXWokMDA4YWJiYjktOTM5Ni03ZTBmLTZhYjMtMDU1MjkwOTgxYzg5cikwaC5mfG1lbWJlcnNoaXB8MTAwMzdmZmU4YjNmYmZiN0BsaXZlLmNvbXoBMoIBEgnLjvhBY8pNQBGX3asKFp_ROJIBBUpvdmFumgEIVHJ1amlsbG-iARhqdHJ1amlsMUBhc3VyaXRlLmFzdS5lZHWqARAxMDAzN0ZGRThCM0ZCRkI3sgE6Z3JvdXAucmVhZCBhbGxmaWxlcy5yZWFkIGFsbHByb2ZpbGVzLnJlYWQgYWxscHJvZmlsZXMucmVhZMgBAQ.-OQVw_jRB4hFPO1FKSXenSkf2psJtmc2bb2K5sY7zUg&ApiVersion=2.0&web=1)
sub parse_vgs_rev {
  my ($path) = @_;
  open my $fh, '<', $path or die $!;
  my $hdr = <$fh>; # "'VD'(1)\t'ID'(1)\t'VG'(1)\t'IG'(1)"
  my (@vd,@id,@vg,@ig);
  while (my $line = <$fh>) {
    next if $line =~ /^\s*$/;
    my @t = split /\t/, $line;
    push @vd, parse_num($t[0]);
    push @id, parse_num($t[1]);
    push @vg, parse_num($t[2]);
    push @ig, parse_num($t[3]);
  }
  close $fh;
  return {vd=>\@vd, id=>\@id, vg=>\@vg, ig=>\@ig};
}

# ids_vgs_tacta: columns repeating [VG IG VD ID] for multiple groups (VD steps)  [1](https://arizonastateu-my.sharepoint.com/personal/jtrujil1_asurite_asu_edu/_layouts/15/download.aspx?UniqueId=66cc7aa9-853b-4fd7-b526-1efda1ed52d9&Translate=false&tempauth=v1.eyJzaXRlaWQiOiJjZjliNzBmYS0wZjc2LTQxYWUtYjY2Mi05OWY2YmY3Y2RiYzYiLCJhcHBfZGlzcGxheW5hbWUiOiJPZmZpY2UgMzY1IFNlYXJjaCBTZXJ2aWNlIiwiYXBwaWQiOiI2NmE4ODc1Ny0yNThjLTRjNzItODkzYy0zZThiZWQ0ZDY4OTkiLCJhdWQiOiIwMDAwMDAwMy0wMDAwLTBmZjEtY2UwMC0wMDAwMDAwMDAwMDAvYXJpem9uYXN0YXRldS1teS5zaGFyZXBvaW50LmNvbUA0MWY4OGVjYi1jYTYzLTQwNGQtOTdkZC1hYjBhMTY5ZmQxMzgiLCJleHAiOiIxNzU4MTM1NjU1In0.CkAKDGVudHJhX2NsYWltcxIwQ1BycXE4WUdFQUFhRmt4VVZqUk9hVms0VkZVeVRURlhWVkU1YVVKRVFVRXFBQT09CjIKCmFjdG9yYXBwaWQSJDAwMDAwMDAzLTAwMDAtMDAwMC1jMDAwLTAwMDAwMDAwMDAwMAoKCgRzbmlkEgI2NBILCPjp8eXFh7s-EAUaDjIwLjE5MC4xMzIuMTA2KixxUUUyZTlwNXVPa0RoemRXSUx6WHdaSUhqeHk2ZzJPY0Jtelk4Wk12em9JPTChATgBQhChxrAwWGAAAOjAkt2yx_yHShBoYXNoZWRwcm9vZnRva2VuUghbImttc2kiXWokMDA4YWJiYjktOTM5Ni03ZTBmLTZhYjMtMDU1MjkwOTgxYzg5cikwaC5mfG1lbWJlcnNoaXB8MTAwMzdmZmU4YjNmYmZiN0BsaXZlLmNvbXoBMoIBEgnLjvhBY8pNQBGX3asKFp_ROJIBBUpvdmFumgEIVHJ1amlsbG-iARhqdHJ1amlsMUBhc3VyaXRlLmFzdS5lZHWqARAxMDAzN0ZGRThCM0ZCRkI3sgE6Z3JvdXAucmVhZCBhbGxmaWxlcy5yZWFkIGFsbHByb2ZpbGVzLnJlYWQgYWxscHJvZmlsZXMucmVhZMgBAQ.XVDN_VsbbFyItJlRG3BN9oT43VRqGlx6Z68BUo8f4QE&ApiVersion=2.0&web=1)
sub parse_vgs_fwd {
  my ($path) = @_;
  open my $fh, '<', $path or die $!;
  my $hdr = <$fh>;
  my @cols = split /\t/, $hdr;
  # Count groups by chunks of 4
  my $groups = int(@cols/4);
  my @vg; my @ig; my @vd; my @id;
  for (1..$groups) { push @vg, []; push @ig, []; push @vd, []; push @id, []; }
  while (my $line = <$fh>) {
    next if $line =~ /^\s*$/;
    my @t = split /\t/, $line;
    for my $g (0..$groups-1) {
      my $base = $g*4;
      push @{$vg[$g]}, parse_num($t[$base+0]);
      push @{$ig[$g]}, parse_num($t[$base+1]);
      push @{$vd[$g]}, parse_num($t[$base+2]);
      push @{$id[$g]}, parse_num($t[$base+3]);
    }
  }
  close $fh;
  return {groups=>$groups, vg=>\@vg, ig=>\@ig, vd=>\@vd, id=>\@id};
}

# ids_vds_tacta: columns repeating [VG IG VD ID] for multiple VG groups  [3](https://arizonastateu-my.sharepoint.com/personal/jtrujil1_asurite_asu_edu/_layouts/15/download.aspx?UniqueId=d5782428-582d-47d5-abb7-214485da2fce&Translate=false&tempauth=v1.eyJzaXRlaWQiOiJjZjliNzBmYS0wZjc2LTQxYWUtYjY2Mi05OWY2YmY3Y2RiYzYiLCJhcHBfZGlzcGxheW5hbWUiOiJPZmZpY2UgMzY1IFNlYXJjaCBTZXJ2aWNlIiwiYXBwaWQiOiI2NmE4ODc1Ny0yNThjLTRjNzItODkzYy0zZThiZWQ0ZDY4OTkiLCJhdWQiOiIwMDAwMDAwMy0wMDAwLTBmZjEtY2UwMC0wMDAwMDAwMDAwMDAvYXJpem9uYXN0YXRldS1teS5zaGFyZXBvaW50LmNvbUA0MWY4OGVjYi1jYTYzLTQwNGQtOTdkZC1hYjBhMTY5ZmQxMzgiLCJleHAiOiIxNzU4MTM1NjU1In0.CkAKDGVudHJhX2NsYWltcxIwQ1BycXE4WUdFQUFhRmt4VVZqUk9hVms0VkZVeVRURlhWVkU1YVVKRVFVRXFBQT09CjIKCmFjdG9yYXBwaWQSJDAwMDAwMDAzLTAwMDAtMDAwMC1jMDAwLTAwMDAwMDAwMDAwMAoKCgRzbmlkEgI2NBILCOjgqufFh7s-EAUaDjIwLjE5MC4xMzIuMTA2Kix3ajdVYlFYSXpudktjY25USG9ZYkVQMWZwY252cCtQTzd5Y1FtSnY3YzRJPTChATgBQhChxrAwYtAAAPnMgdxVvClkShBoYXNoZWRwcm9vZnRva2VuUghbImttc2kiXWokMDA4YWJiYjktOTM5Ni03ZTBmLTZhYjMtMDU1MjkwOTgxYzg5cikwaC5mfG1lbWJlcnNoaXB8MTAwMzdmZmU4YjNmYmZiN0BsaXZlLmNvbXoBMoIBEgnLjvhBY8pNQBGX3asKFp_ROJIBBUpvdmFumgEIVHJ1amlsbG-iARhqdHJ1amlsMUBhc3VyaXRlLmFzdS5lZHWqARAxMDAzN0ZGRThCM0ZCRkI3sgE6Z3JvdXAucmVhZCBhbGxmaWxlcy5yZWFkIGFsbHByb2ZpbGVzLnJlYWQgYWxscHJvZmlsZXMucmVhZMgBAQ.L5IE0-NXE2PCs19YuBkW6X9dwHuhFRFrl0Vht9ol0bY&ApiVersion=2.0&web=1)
sub parse_vds {
  my ($path) = @_;
  open my $fh, '<', $path or die $!;
  my $hdr = <$fh>;
  my @cols = split /\t/, $hdr;
  my $groups = int(@cols/4);
  my @vg; my @ig; my @vd; my @id;
  for (1..$groups) { push @vg, []; push @ig, []; push @vd, []; push @id, []; }
  while (my $line = <$fh>) {
    next if $line =~ /^\s*$/;
    my @t = split /\t/, $line;
    for my $g (0..$groups-1) {
      my $base = $g*4;
      push @{$vg[$g]}, parse_num($t[$base+0]);
      push @{$ig[$g]}, parse_num($t[$base+1]);
      push @{$vd[$g]}, parse_num($t[$base+2]);
      push @{$id[$g]}, parse_num($t[$base+3]);
    }
  }
  close $fh;
  return {groups=>$groups, vg=>\@vg, ig=>\@ig, vd=>\@vd, id=>\@id};
}

# ---------------- Discover files ----------------
sub glob_like { my ($pat) = @_; glob(File::Spec->catfile($data_dir, $pat)) }

my ($f_vgs_fwd) = glob_like($cfg->{file_patterns}{ids_vgs_fwd} // 'ids_vgs_tacta_*.txt');
my ($f_vgs_rev) = glob_like($cfg->{file_patterns}{ids_vgs_rev} // 'ids_vgs_rev_tacta_*.txt');
my ($f_vds)     = glob_like($cfg->{file_patterns}{ids_vds}     // 'ids_vds_tacta_*.txt');

$f_vgs_fwd or die "Missing ids_vgs_tacta_* file in $data_dir\n";
$f_vgs_rev or die "Missing ids_vgs_rev_tacta_* file in $data_dir\n";
$f_vds     or die "Missing ids_vds_tacta_* file in $data_dir\n";

say "Found:";
say "  VGS FWD: $f_vgs_fwd";
say "  VGS REV: $f_vgs_rev";
say "  VDS:     $f_vds";

# ---------------- Parse all ----------------
my $meta = parse_meta_from_name(basename($f_vgs_fwd));
my $root = File::Spec->catdir('out', $meta->{lot}, "Wafer_$meta->{wafer}", $meta->{site});
ensure_dir($root);

my $rev = parse_vgs_rev($f_vgs_rev);
my $fwd = parse_vgs_fwd($f_vgs_fwd);
my $vds = parse_vds($f_vds);

# ---------------- Emit tidy CSVs ----------------
# 1) reverse transfer (single sweep)
{
  my $rows = [ [qw(point VG VD ID IG)] ];
  for my $i (0..$#{$rev->{vg}}) {
    push @$rows, [ $i, $rev->{vg}[$i], $rev->{vd}[$i], $rev->{id}[$i], $rev->{ig}[$i] ];
  }
  csv_out(File::Spec->catfile($root, "transfer_rev.csv"), $rows);
}

# 2) forward transfer (multi-VD groups)
{
  my $rows = [ [qw(group point VG VD ID IG)] ];
  for my $g (0..$fwd->{groups}-1) {
    for my $i (0..$#{$fwd->{vg}[$g]}) {
      push @$rows, [ $g+1, $i, $fwd->{vg}[$g][$i], $fwd->{vd}[$g][$i], $fwd->{id}[$g][$i], $fwd->{ig}[$g][$i] ];
    }
  }
  csv_out(File::Spec->catfile($root, "transfer_fwd.csv"), $rows);
}

# 3) output curves (multi-VG groups)
{
  my $rows = [ [qw(group point VG VD ID IG)] ];
  for my $g (0..$vds->{groups}-1) {
    for my $i (0..$#{$vds->{vd}[$g]}) {
      push @$rows, [ $g+1, $i, $vds->{vg}[$g][$i], $vds->{vd}[$g][$i], $vds->{id}[$g][$i], $vds->{ig}[$g][$i] ];
    }
  }
  csv_out(File::Spec->catfile($root, "output_curves.csv"), $rows);
}

# ---------------- Metrics (basic) ----------------
my $vd_target = $cfg->{vd_target_for_transfer} // 10.0;
my $vg_on_tgt = $cfg->{vg_on_for_on_current} // 9.0;
my $vg_off_tgt= $cfg->{vg_off_for_off_current} // -5.0;

# Prefer reverse transfer at VD~target (your reverse file is ~10V)  [2](https://arizonastateu-my.sharepoint.com/personal/jtrujil1_asurite_asu_edu/_layouts/15/download.aspx?UniqueId=5b87835a-b126-445b-9875-0bcfebd30209&Translate=false&tempauth=v1.eyJzaXRlaWQiOiJjZjliNzBmYS0wZjc2LTQxYWUtYjY2Mi05OWY2YmY3Y2RiYzYiLCJhcHBfZGlzcGxheW5hbWUiOiJPZmZpY2UgMzY1IFNlYXJjaCBTZXJ2aWNlIiwiYXBwaWQiOiI2NmE4ODc1Ny0yNThjLTRjNzItODkzYy0zZThiZWQ0ZDY4OTkiLCJhdWQiOiIwMDAwMDAwMy0wMDAwLTBmZjEtY2UwMC0wMDAwMDAwMDAwMDAvYXJpem9uYXN0YXRldS1teS5zaGFyZXBvaW50LmNvbUA0MWY4OGVjYi1jYTYzLTQwNGQtOTdkZC1hYjBhMTY5ZmQxMzgiLCJleHAiOiIxNzU4MTM1NjU1In0.CkAKDGVudHJhX2NsYWltcxIwQ1BycXE4WUdFQUFhRmt4VVZqUk9hVms0VkZVeVRURlhWVkU1YVVKRVFVRXFBQT09CjIKCmFjdG9yYXBwaWQSJDAwMDAwMDAzLTAwMDAtMDAwMC1jMDAwLTAwMDAwMDAwMDAwMAoKCgRzbmlkEgI2NBILCOTjgurFh7s-EAUaDjIwLjE5MC4xMzIuMTA2Kiw5QkVpOG56UFNRVTFaUkJZaWRzTzBZYUtLNm43NnVrNFJ5T0NmWHQ5b1VJPTChATgBQhChxrAwdWAAAOjAlTyp25N4ShBoYXNoZWRwcm9vZnRva2VuUghbImttc2kiXWokMDA4YWJiYjktOTM5Ni03ZTBmLTZhYjMtMDU1MjkwOTgxYzg5cikwaC5mfG1lbWJlcnNoaXB8MTAwMzdmZmU4YjNmYmZiN0BsaXZlLmNvbXoBMoIBEgnLjvhBY8pNQBGX3asKFp_ROJIBBUpvdmFumgEIVHJ1amlsbG-iARhqdHJ1amlsMUBhc3VyaXRlLmFzdS5lZHWqARAxMDAzN0ZGRThCM0ZCRkI3sgE6Z3JvdXAucmVhZCBhbGxmaWxlcy5yZWFkIGFsbHByb2ZpbGVzLnJlYWQgYWxscHJvZmlsZXMucmVhZMgBAQ.-OQVw_jRB4hFPO1FKSXenSkf2psJtmc2bb2K5sY7zUg&ApiVersion=2.0&web=1)
my $vg_rev = $rev->{vg};
my $id_rev = $rev->{id};
my $vd_rev = $rev->{vd};

# On/off & leakage at reverse sweep (use nearest VG to targets)
my $i_on; my $i_off; my $i_gleak_at_on; my $i_gleak_at_off;
{
  my $i_on_idx  = nearest_idx($vg_rev, $vg_on_tgt);
  my $i_off_idx = nearest_idx($vg_rev, $vg_off_tgt);
  $i_on  = $id_rev->[$i_on_idx];
  $i_off = $id_rev->[$i_off_idx];
  $i_gleak_at_on  = $rev->{ig}[$i_on_idx];
  $i_gleak_at_off = $rev->{ig}[$i_off_idx];
}
my $on_off = (defined $i_on && defined $i_off && abs($i_off)>0) ? abs($i_on/$i_off) : undef;

# Vth & gm,max (simple linear extrapolation) from reverse sweep Id(Vg) at ~constant Vd
my ($vth, $gm_max) = vth_from_linear_extrap($vg_rev, $id_rev);

# Hysteresis ΔVg@Id_ref between fwd and rev at Vd≈target:
# pick VD group in fwd whose VD is closest to $vd_target (at first point), then compare VG at same Id
my $best_g = 0; my $best_d = 1e99;
for my $g (0..$fwd->{groups}-1) {
  my $d = abs( ($fwd->{vd}[$g][0] // 0) - $vd_target );
  if ($d < $best_d) { $best_d=$d; $best_g=$g; }
}
# choose a reference current Id_ref = Id at VG≈vg_on_tgt on reverse sweep
my $id_ref = $i_on;
sub interp_x_for_y {
  my ($x,$y,$yref) = @_;
  for my $i (1..$#$x) {
    my ($x1,$y1,$x2,$y2) = ($x->[$i-1],$y->[$i-1],$x->[$i],$y->[$i]);
    next if ($y2-$y1)==0;
    # check crossing
    if (($yref-$y1)*($yref-$y2) <= 0) {
      my $t = ($yref-$y1)/($y2-$y1);
      return $x1 + $t*($x2-$x1);
    }
  }
  return undef;
}
my $vg_at_id_fwd = interp_x_for_y($fwd->{vg}[$best_g], $fwd->{id}[$best_g], $id_ref);
my $vg_at_id_rev = interp_x_for_y($vg_rev, $id_rev, $id_ref);
my $dvg_hyst = (defined $vg_at_id_fwd && defined $vg_at_id_rev) ? ($vg_at_id_fwd - $vg_at_id_rev) : undef;

# Emit metrics
{
  my $rows = [
    [qw(Lot Wafer Site VD_target VG_on VG_off Ion(A) Ioff(A) OnOff gm_max(A/V) Vth_lin(V) Hyst_dVg_at_Ion(V) GateLeak_at_ON(A) GateLeak_at_OFF(A))],
    [$meta->{lot}, $meta->{wafer}, $meta->{site},
     $vd_target, $vg_on_tgt, $vg_off_tgt,
     $i_on//"", $i_off//"", $on_off//"",
     (defined $gm_max ? $gm_max : ""), (defined $vth ? $vth : ""),
     (defined $dvg_hyst ? $dvg_hyst : ""),
     $i_gleak_at_on//"", $i_gleak_at_off//""]
  ];
  csv_out(File::Spec->catfile($root, "metrics.csv"), $rows);
}

# ---------------- Gnuplot scripts & PNGs ----------------
my $plt_dir = 'gnuplot_templates';
ensure_dir($plt_dir);
my ($W,$H) = @{$cfg->{plots}{size_px} // [1600,1000]};
my $term   = $cfg->{plots}{terminal} // 'pngcairo';
my $font   = $cfg->{plots}{font}     // 'Arial';

sub write_plt {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "Write $path: $!";
  print $fh $content; close $fh;
}

my $transfer_fwd_csv = File::Spec->catfile($root, "transfer_fwd.csv");
my $transfer_rev_csv = File::Spec->catfile($root, "transfer_rev.csv");
my $output_csv       = File::Spec->catfile($root, "output_curves.csv");

# Id-Vd family (linear and log) from output_curves.csv
for my $scale (qw(linear log)) {
  my $png = File::Spec->catfile($root, sprintf("Id_Vd_family_%s.png",$scale));
  my $plt = File::Spec->catfile($plt_dir, sprintf("Id_Vd_family_%s.plt",$scale));
  my $logy = $scale eq 'log' ? "set logscale y" : "unset logscale y";
  my $body = <<"PLT";
set term $term size $W,$H font "$font,12"
set output "$png"
set datafile separator ','
$logy
set key outside bottom center horizontal spacing 1.2
set grid
set title "Id-Vd (Output Curves) - $meta->{lot} Wafer $meta->{wafer} $meta->{site}"
set xlabel "Vd (V)"
set ylabel "Id (A)"
# plot each group as a separate curve
plot for [g=1:*] "$output_csv" u (strcol(1)==sprintf("%d",g)? \$4:1/0):(strcol(1)==sprintf("%d",g)? \$5:1/0) w lp lw 2 t sprintf("VG group %d",g)
PLT
  write_plt($plt,$body);
  system("gnuplot",$plt)==0 or warn "gnuplot failed: $plt\n";
}

# Id-Vg (forward vs reverse) linear + log
for my $scale (qw(linear log)) {
  my $png = File::Spec->catfile($root, sprintf("Id_Vg_fwd_vs_rev_%s.png",$scale));
  my $plt = File::Spec->catfile($plt_dir, sprintf("Id_Vg_fwd_vs_rev_%s.plt",$scale));
  my $logy = $scale eq 'log' ? "set logscale y" : "unset logscale y";
  my $body = <<"PLT";
set term $term size $W,$H font "$font,12"
set output "$png"
set datafile separator ','
$logy
set key outside bottom center horizontal spacing 1.2
set grid
set title "Id-Vg (Forward vs Reverse) - $meta->{lot} Wafer $meta->{wafer} $meta->{site}"
set xlabel "Vg (V)"
set ylabel "Id (A)"
# Choose the fwd group whose Vd is closest to $vd_target (precomputed in CSV by group values)
# We'll plot the mode where group==$best_g+1 for FWD and the single REV curve
plot "$transfer_fwd_csv" u (\$1==$best_g+1?\$3:1/0):(\$1==$best_g+1?\$5:1/0) w lp lc rgb "#1f77b4" lw 2 pt 7 t sprintf("Fwd Vd~%.1fV (group %d)",$vd_target,$best_g+1), \
     "$transfer_rev_csv" u 2:4 w lp lc rgb "#d62728" lw 2 pt 5 t "Reverse (Vd~10V)"
PLT
  write_plt($plt,$body);
  system("gnuplot",$plt)==0 or warn "gnuplot failed: $plt\n";
}

# Ig-Vg (gate leakage), log scale
{
  my $png = File::Spec->catfile($root, "Ig_Vg_log.png");
  my $plt = File::Spec->catfile($plt_dir, "Ig_Vg_log.plt");
  my $body = <<"PLT";
set term $term size $W,$H font "$font,12"
set output "$png"
set datafile separator ','
set logscale y
set grid
set title "Ig-Vg (Gate Leakage) - $meta->{lot} Wafer $meta->{wafer} $meta->{site}"
set xlabel "Vg (V)"
set ylabel "Ig (A)"
plot "$transfer_fwd_csv" u (\$1==$best_g+1?\$3:1/0):(\$1==$best_g+1?\$6:1/0) w lp lw 2 lc rgb "#2ca02c" t "Fwd (Vd~$vd_target V)", \
     "$transfer_rev_csv" u 2:5 w lp lw 2 lc rgb "#9467bd" t "Reverse (Vd~10 V)"
PLT
  write_plt($plt,$body);
  system("gnuplot",$plt)==0 or warn "gnuplot failed: $plt\n";
}

say "PNG plots and CSVs are under: $root";
say "Done.";

