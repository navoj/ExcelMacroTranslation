#!/usr/bin/env perl
use Modern::Perl;
use Test;

BEGIN { plan tests => 13, todo => [2] }

use ETest;

my @Wafer_List;

print "# Testing Environment initialization\n";
ok $Environment{'Lot_ID'}, "blank";
ok $Environment{'Wafer_List'}, \@Wafer_List;
ok $Environment{'Path_To_Data_File'}, "./";
ok $Environment{'Test_Name_For_Processing'}, "COW";
ok $Environment{'Analysis_Master_Name'} , "AnalysisMaster_Autoprobe_Prod_20111005";
ok $Environment{'Test_Descriptor_Keys_File'}, "(compute)";
ok $Environment{'Append'}, False;
ok $Environment{'Process_Reverse_Sweeps'}, True;
ok $Environment{'Print_Graphs'}, True;
ok $Environment{'Print_Graphs_To_File'}, True;
ok $Environment{'Delete_Summary_Filenames_Sheets'}, False;
ok $Environment{'DEBUG'}, True;

print "# Testing prompt() function\n";
ok prompt("Enter a 1"), 1;

print "# Testing fileList() function\n";

1;





