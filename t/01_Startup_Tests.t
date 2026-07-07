#!/usr/bin/env perl
use Modern::Perl;
use Test;
use constant { True => 1, False => 0 };

BEGIN { plan tests => 13, todo => [2] }

use ETest;

my @Wafer_List;

print "# Testing Environment initialization\n";
ok $Environment{'Lot_ID'}, "blank"; # Test 1
ok $Environment{'Wafer_List'}, $Environment{'Wafer_List'};	# Test 2
ok $Environment{'Path_To_Data_File'}, "./";	# Test 3
ok $Environment{'Test_Name_For_Processing'}, "COW";	# Test 4
ok $Environment{'Analysis_Master_Name'} , "AnalysisMaster_Autoprobe_Prod_20111005";	# Test 5
ok $Environment{'Test_Descriptor_Keys_File'}, "(compute)";	# Test 6
ok $Environment{'Append'}, False;	# Test 7
ok $Environment{'Process_Reverse_Sweeps'}, True;	# Test 8
ok $Environment{'Print_Graphs'}, True;	# Test 9	
ok $Environment{'Print_Graphs_To_File'}, True;	# Test 10
ok $Environment{'Delete_Summary_Filenames_Sheets'}, False;	# Test 11
ok $Environment{'DEBUG'}, True;	# Test 12

print "# Testing prompt() function\n";
print "# Enter a 1 now:\n";
my $response = ETest::prompt("Enter a 1");
chomp $response;
ok $response, "1";	# Test 13

#print "# Testing fileList() function\n";

1;





