#!/usr/bin/env perl6
use v6;
use File::Find;

my $Append = False;
my $Test_Descriptor_Keys_File = "(compute)";
my $Lot_ID = "E1517-002";
my @Wafer_List = "Wafer_11", "Wafer_12";
my $Analysis_Master_Name = "AnalysisMaster_Autoprobe_Prod_20111005";
my $Test_Name_For_Processing = "COW";
my $Path_To_Data_File = "./"; 
my $Process_Reverse_Sweeps = 1;
my $Print_Graphs = 1;
my $Print_Graphs_To_File = 1;
my $Delete_Summary_Filename_Sheets = 0;
my %Environment = 
    Lot_ID => $Lot_ID, 
    Wafer_List => @Wafer_List, 
    Path_To_Data_File => $Path_To_Data_File, 
    Test_Name_For_Processing => $Test_Name_For_Processing, 
    Analysis_Master_Name => $Analysis_Master_Name,
    Test_Descriptor_Keys_File => $Test_Descriptor_Keys_File, 
    Append => $Append, 
    Process_Reverse_Sweeps => $Process_Reverse_Sweeps,
    Print_Graphs => $Print_Graphs, 
    Print_Graphs_To_File => $Print_Graphs_To_File, 
    Delete_Summary_Filenames_Sheets => $Delete_Summary_Filename_Sheets,
    DEBUG => True;

sub main() {
    say "Starting...";
    my $myReturn = 1;
    my $myInput = "";
    my $PrintGraphsStatus = "(yes)";
    my $PrintGraphsToFileStatus = "(yes)";
    my $ProcessReverseSweeps = "(yes)";
    my $AppendDataToSummary = "(no)";

    while ($myReturn) {
	say "Choose Function: ";
	say "1. Process TFT Autoprobe Data";
	say "2. Process TFT Princeton Data";
	say "3. Print Graphs? " ~ $PrintGraphsStatus;
	say "4. Print Graphs to File? " ~ $PrintGraphsToFileStatus;
	say "5. Process TFT Data";
	say "6. Delete Summary & Filenames Sheets";
	say "7. Process Reverse Sweeps " ~ $ProcessReverseSweeps;
	say "8. Append Data to Summary " ~ $AppendDataToSummary;
	say "9. Quit";

	$myInput = get();

	given ($myInput) {
	    when 1 { $myReturn = &Process_TFT_Autoprobe_Data(%Environment); }
	    when 2 { $myReturn = &Process_TFT_Princeton_Data(%Environment); }
	    when 3 { $myReturn = &Print_Graphs(%Environment); }
	    when 4 { $myReturn = &Print_Graphs_To_File(%Environment); }
	    when 5 { $myReturn = &Process_TFT_Data(%Environment); }
	    when 6 { $myReturn = &Delete_Summary_Filenames_Sheets(%Environment); } 
	    when 7 { $myReturn = &Process_Reverse_Sweeps(%Environment); }
	    when 8 { $myReturn = &Append_Data_to_Summary(%Environment); }
	    when 9 { return(0); }
	    default { $myReturn = 1; }
	}
    }
}

sub Process_TFT_Autoprobe_Data(%Environment) {
    my $Lot_ID = %Environment{'Lot_ID'};
    my @WaferList = %Environment{'Wafer_List'};
    my $Path_To_Data_File = %Environment{'Path_To_Data_File'};
    my $currentPath = "";
    my $DEBUG = %Environment{'DEBUG'};
    my $file; 
    my @data;
    my @header;
    my $count;
    my $dh;
    my @fileList;
    my @summary;
    my $UseTestDescriptorKeys = True;
    my @SiteList;
    my @uidList;
    my @DeviceList;

    if (%Environment{'Test_Descriptor_Keys_File'} ~~ /(compute)/) {
	$UseTestDescriptorKeys = False;
    }

    if ($UseTestDescriptorKeys == True) {
	# We need to read the TestDescriptorKeys Excel file here;
	my $testIdentifier;
	my $totalSites;
	my $KeyFile;
	my $FullKeyName;
	# First, open the TestDescriptorKeys Workbook and switch to the specified Worksheet
    }

    say "Enter your lot ID:";
    $Lot_ID = get();
    while (not ($Lot_ID.IO ~~ :d)) {
	say "Enter your lot ID:";
	if ($Lot_ID ~~ rx:i/exit|quit/) {
	    return(1);
	}
	$Lot_ID = get();
    }
    
    $Path_To_Data_File ~=  $Lot_ID;

    while (($count = prompt "How many wafers?") <= 0) {
	if ($count == 0) {
	    return(1);
	}
    }

    loop (my $i = 0; $i < $count; $i++) {
	@WaferList[$i] = prompt "Wafer Name: ";
    }
    
    for @WaferList -> $wafer {
	$currentPath = $Path_To_Data_File ~ "/" ~ $wafer;
	if (not ($currentPath.IO ~~ :d)) {
	    say "$currentPath does not exist. Exiting now.";
	    return(1);
	}
	# Now that we have a path to data file it's time to process it and generate a summary file. 
	# Need to check if there is a module for generating Excel spreadsheets from an array of data. 
	@fileList := find(dir => $currentPath, name => /ids_vds/);
	for @fileList -> $f {
	    if ($f ~~ /hf_ids_vds/) { 
		$file = open($f);
		$file.seek(0,0);
		@header = $file.get.split(/\t/);
		@data = map {[.split(/\t/)]}, $file.lines;

		
		
		if ($DEBUG) {
		    say "currentPath: " ~ $f;
		    say "data length: " ~ @data.elems;
		}
	    }
	}
    }
    

    
    if ($DEBUG) {
	say "called Process TFT Autoprobe Data";
    }
}



sub Process_TFT_Princeton_Data(%Environment) {
    
    say "called Process TFT Princeton Data";
}

sub Print_Graphs(%Environment) {
    say "called Print Graphs";
}

sub Print_Graphs_To_File(%Environment) {
    say "called Print Graphs to File";
}

sub Process_TFT_Data(%Environment) {
    say "called Process TFT Data";
}

sub Delete_Summary_Filenames_Sheets(%Environment) {
    say "called Delete Summary Filenames Sheets";
}

sub Process_Reverse_Sweeps(%Environment) {
    say "called Process Reverse Sweeps";
}

sub Append_Data_to_Summary(%Environment) {
    say "called Append Data to Summary";
}

main();

1;


