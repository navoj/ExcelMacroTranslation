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
    Lot_ID => "E1517-002", 
    Wafer_List => <"Wafer_11" "Wafer_12">, 
    Path_To_Data_File => "../", 
    Test_Name_For_Processing => "COW", 
    Analysis_Master_Name => "AnalysisMaster_Autoprobe_Prod_20111005",
    Test_Descriptor_Keys_File => "(compute)", 
    Append => $Append, 
    Process_Reverse_Sweeps => $Process_Reverse_Sweeps,
    Print_Graphs => $Print_Graphs, 
    Print_Graphs_To_File => $Print_Graphs_To_File, 
    Delete_Summary_Filenames_Sheets => $Delete_Summary_Filename_Sheets,
    DEBUG => True;

sub main(%Environment) {
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
	say "3. Process TFT Data";
	say "4. Print Graphs? " ~ $PrintGraphsStatus;
	say "5. Print Graphs to File? " ~ $PrintGraphsToFileStatus;
	say "6. Delete Summary & Filenames Sheets?" ~ $Delete_Summary_Filename_Sheets; 
	say "7. Process Reverse Sweeps? " ~ $ProcessReverseSweeps;
	say "8. Append Data to Summary? " ~ $AppendDataToSummary;
	say "9. Path To Lot: " ~ $Path_To_Data_File;
	say "10. Analysis Master File Name: " ~ $Analysis_Master_Name;
	say "11. Test Descriptor Keys Name: " ~ $Test_Descriptor_Keys_File;
	say "12. Test Name For Processing: " ~ $Test_Name_For_Processing;
	say "13. Quit";

	$myInput = get();

	given ($myInput) {
	    when 1 { $myReturn = &ProcessTFTAutoprobeData(%Environment); }
	    when 2 { $myReturn = &ProcessTFTPrincetonData(%Environment); }
	    when 3 { $myReturn = &ProcessTFTData(%Environment); }
	    when 4 { $myReturn = &setPrintGraphs(%Environment); }
	    when 5 { $myReturn = &setPrintGraphsToFile(%Environment); }
	    when 6 { $myReturn = &setDeleteSummaryFilenamesSheets(%Environment); } 
	    when 7 { $myReturn = &setProcessReverseSweeps(%Environment); }
	    when 8 { $myReturn = &setAppendDataToSummary(%Environment); }
	    when 9 { $myReturn = &setPathToLot(%Environment); }
	    when 10 { $myReturn = &setAnalysisMasterFileName(%Environment); }
	    when 11 { $myReturn = &setTestDescriptorKeysName(%Environment); }
	    when 12 { $myReturn = &setTestNameForProcessing(%Environment); }
	    when 13 { $myReturn = 0; }
	    default { $myReturn = 1; }
	}
    }
}

sub ProcessTFTAutoprobeData(%Environment) {
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
    my $ProcessHysteresis;
    my $ProcessGate;


    %Environment{'Test_Descriptor_Keys_File'} = prompt "Enter Test Descriptor KEys File or \"(compute)\"";
    if (%Environment{'Test_Descriptor_Keys_File'} ~~ /(compute)/) {
	$UseTestDescriptorKeys = False;
    } else {
	if (%Environment{'Test_Descriptor_Keys_File'} ~~ /\s+/) {
	    say "Invalid Test Descriptor Keys File";
	    return(1);
	}
    }

    # Display current analysis setup
    say "Current setup: ";
    say "Path to Lot: " ~ %Environment{'Path_To_Data_File'};
    say "Analysis Master File: " ~ %Environment{'Analysis_Master_Name'};
    say "Test Descriptor Keys File: " ~ %Environment{'Test_Descriptor_Keys_File'};
    say "Test Name For Processing: " ~ %Environment{'Test_Name_For_Processing'};
    say "Process Reverse Sweeps?: " ~ %Environment{'Process_Reverse_Sweeps'};
    say "Append Data to Summary?: " ~ %Environment{'Append'};
    say "Print Graphs?: " ~ %Environment{'Print_Graphs'};
    say "Print Graphs To File?: " ~ %Environment{'Print_Graphs_To_File'};
    say "Delete Summary Filenames?: " ~ %Environment{'Delete_Summary_Filenames_Sheets'};

    if ( (my $continue = prompt "Continue?") ~~ re:i/no|n/) {
	return(1);
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



sub ProcessTFTPrincetonData(%Environment) {
    if (%Environment{'DEBUG'} = True) {
	say "called Process TFT Princeton Data";
    }
}

sub setPrintGraphs(%Environment) {
    say "called Print Graphs";
}

sub setPrintGraphsToFile(%Environment) {
    say "called Print Graphs to File";
}

sub ProcessTFTData(%Environment) {
    say "called Process TFT Data";
}


sub setDeleteSummaryFilenamesSheets(%Environment) {
    say "called Delete Summary Filenames Sheets";
}

sub setProcessReverseSweeps(%Environment) {
    say "called Process Reverse Sweeps";
}

sub setAppendDataToSummary(%Environment) {
    say "called Append Data to Summary";
}

sub setPathToLot(%Environment) {
    say "called setPathToLot";
}

sub setAnalysisMasterFileName(%Environment) {
    say "called setAnalysisMasterFileName";

main();

1;


