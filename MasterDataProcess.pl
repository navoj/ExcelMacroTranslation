#!/usr/bin/env perl
use Modern::Perl;
use PDL;
use File::Find;
use Spreadsheet::ParseExcel;
#use feature qw(say switch);

# Global vars
my $Append = False;
my $Test_Descriptor_Keys_File = "(compute)";
my $Lot_ID = "blank";
my @Wafer_List;
my $Analysis_Master_Name = "AnalysisMaster_Autoprobe_Prod_20111005";
my $Test_Name_For_Processing = "COW";
my $Path_To_Data_File = "./";
my $Process_Reverse_Sweeps = True;
my $Print_Graphs = True;
my $Print_Graphs_To_File = True;
my $Delete_Summary_Filename_Sheets = False;
my %Environment = (
	Lot_ID => $Lot_ID,
	Wafer_List => \@Wafer_List,
	Path_To_Data_File => $Path_To_Data_File,
	Test_Name_For_Processing => $Test_Name_For_Processing,
	Analysis_Master_Name => $Analysis_Master_Name,
	Test_Descriptor_Keys_File => $Test_Descriptor_Keys_File,
	Append => $Append,
	Process_Reverse_Sweeps => $Process_Reverse_Sweeps,
	Print_Graphs = $Print_Graphs,
	Print_Graphs_To_File => $Print_Graphs_To_File,
	Delete_Summary_Filenames_Sheets => $Delete_Summary_Filename_Sheets,
	DEBUG => True);

sub main() {
	print("Starting\n");
	my $myReturn = True;
	my $myInput = "";
	my $PrintGraphsStatus = "(yes)";
	my $PrintGraphsToFileStatus = "(yes)";
	my $ProcessReverseSweeps = "(yes)";
	my $AppendDataToSummary = "(no)";
	
	while ($myReturn) {
		print "Choose Function: ";
		print "1. Process TFT Autoprobe Data";
		print "2. Process TFT Princeton Data";
		print "3. Process TFT Data";
		print "4. Print Graphs? " , $PrintGraphsStatus;
		print "5. Print Graphs to File? " , $PrintGraphsToFileStatus;
		print "6. Delete Summary & Filenames Sheets? " , $Delete_Summary_Filename_Sheets;
		print "7. Process Reverse Sweeps? " , $ProcessReverseSweeps;
		print "8. Append Data to Summary? " , $AppendDataToSummary;
		print "9. Path To Lot: ", $Path_To_Data_File;
		print "10. Analysis Master File Name: " , $Analysis_Master_Name;
		print "11. Test Descriptor Keys Name: " , $Test_Descriptor_Keys_File;
		print "12. Test Name For Processing: " , $Test_Name_For_Processing;
		print "13. Quit";
		
		$myInput = <STDIN>;
		
		switch ($myInput) {
			case 1 { $myReturn = &ProcessTFTAutoprobeData(); }
			case 2 { $myReturn = &ProcessTFTPrincetonData(); }
			case 3 { $myReturn = &ProcessTFTData(); }
			case 4 { $myReturn = &setPrintGraphs(); }
			case 5 { $myReturn = &setPrintGraphsToFile(); }
			case 6 { $myReturn = &setDeleteSummaryFilenamesSheets(); }
			case 7 { $myReturn = &setProcessReverseSweeps(); }
			case 8 { $myReturn = &setAppendDataToSummary(); }
			case 9 { $myReturn = &setPathToLot(); }
			case 10 { $myReturn = &setAnalysisMasterFileName(); }
			case 11 { $myReturn = &setTestDescriptorKeysName(); }
			case 12 { $myReturn = &setTestNameForProcessing(); }
			case 13 { $myReturn = 0; }
			default { $myReturn = 1; }
		}
	}
}
	
sub ProcessTFTAutoprobeData() {
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
	my $ProcessHysteresis;
	my $ProcessGate;
	
	%Environment{'Test_Descriptor_Keys_File'} = prompt("Enter Test Descriptor Keys File or \"(compute)\"");
	
	if (%Environment{'Test_Descriptor_Keys_File'} ~= /\(compute\)/) {
		$UseTestDescriptorKeys = False;
	} else {
		if (%Environment{'Test_Descriptor_Keys_File'} ~= /\s+/) {
			print("Invalid Test Descriptor Keys File");
			return(1);
		}
	}
	
	# Display current analysis setup
	say "Current Setup: ";
	say "Path to Lot: " , %Environment{'Path_To_Data_File'};
	say "Analysis Master File: " , %Environment{'Analysis_Master_Name'};
	say "Test Descriptor Keys File: " , %Environment{'Test_Descriptor_Keys_File'};
	say "Test Name For Processing: " , %Environment{'Test_Name_For_Processing'};
	say "Process Reverse Sweeps?: " , %Environment{'Process_Reverse_Sweeps'};
	say "Append Data to Summary?: " , %Environment{'Append'};
	say "Print Graphs?: " , %Environment{'Print_Graphs'};
	say "Print Graphs to File?: " , %Environment{'Print_Graphs_To_File'};
	say "Delete Summary Filenames?: " , %Environment{'Delete_Summary_Filenames_Sheets'};
	
	if ( (my $continue = prompt("Continue?") ~= /no|n|No/) {
		return(1);
	}
	
	if ($UseTestDesriptorKeys == True) {
		# We need to read teh TestDesriptorKeys Excel file here;
		my $testIdentifier;
		my $totalSites;
		my $KeyFile;
		my $FullKeyName;
		# First, open the TestDescriptorKeys Workbook and switch to the specified Worksheet
		my $parse = Spreadsheet::ParseExcel->new();
		my $workbook = $parser->parse(%Environment{'Test_Descriptor_Keys_File'});
		
		if ( !defined $workbook ) {
			die $parser->error(), ".\n";
		}
		
		# Not really what I want to do with TestDescriptorKeys workbook but this helps me learn
		# how to use perl spreadsheet reader. 
		for my $worksheet ( $workbook->worksheets() ) {
			my ( $row_min, $row_max ) = $worksheet->row_range();
			my ( $col_min, $col_max ) = $worksheet->col_range();
			
			for my $row ( $row_min .. $row_max ) {
				for my $col ( $col_min .. $col_max ) {
					my $cell = $worksheet->get_cell( $row, $col );
					next unless $cell;
					
					print "Row, Col      = ($row, $col)\n";
					print "Value         = ", $cell->value(), "\n";
					print "Unformatted   = ", $cell->unformatted(), "\n";
					print "\n";
				}
			}
		}
	}
	
	say "Enter your lot ID: ";
	$Lot_ID = <STDIN>;
	while (not (-e $Lot_ID and -d $Lot_ID)) {
		say "Enter your lot ID: ";
		if ($Lot_ID ~= /exit|quit|EXIT|QUIT/) {
			return(1);
		}
		$Lot_ID = <STDIN>;
	}
	
	$Path_To_Data_File .= $Lot_ID;
	
	while (($count = prompt("How many wafers?")) <= 0) {
		if ($count == 0) {
			return(1);
		}
	}
	
	for (my $i = 0; $i < $count; $i++) {
		@WaferList[$i] = prompt("Wafer Name: ");
	}
	
	foreach $wafer (@WaferList) {
		$currentPath = $Path_To_Data_File . "/" . $wafer;
		if (not (-e $currentPath and -d $currentPath)) {
			say "$currentPath does not exist. Exiting now.";
			return(1);
		}
		# Now that we have a path to data file it's time to process if and generate a summary file.
		# Need to check if there is a module for generating Excel spreadsheets from an array of data. 
		find(\&fileList, $currentPath);
}

sub fileList() {
	my $fileName = $_;
	my $f;
	
	# TODO:
	# Look for /ids_vds/ data files and parse them here.
	# Change all ~= to =~ for regex matching in Perl 5. 
	if ($fileName =~ /hf_ids_vds/) {
		open($f, "<$fileName");
		$f.seek(0,0);
		
	
}

sub prompt() {
	my $inStr = shift;

	my $input;
	print($inStr, "\n");
	$input = <STDIN>;
	return($input);
}
	