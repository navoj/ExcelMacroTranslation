#!/usr/bin/env perl
package ETest;
use Modern::Perl;
use PDL;
use File::Find;
use Spreadsheet::ParseExcel;
use parent 'Exporter';

# local vars
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

# Global vars
our %Environment = (
	Lot_ID => $Lot_ID,
	Wafer_List => \@Wafer_List,
	Path_To_Data_File => $Path_To_Data_File,
	Test_Name_For_Processing => $Test_Name_For_Processing,
	Analysis_Master_Name => $Analysis_Master_Name,
	Test_Descriptor_Keys_File => $Test_Descriptor_Keys_File,
	Append => $Append,
	Process_Reverse_Sweeps => $Process_Reverse_Sweeps,
	Print_Graphs => $Print_Graphs,
	Print_Graphs_To_File => $Print_Graphs_To_File,
	Delete_Summary_Filenames_Sheets => $Delete_Summary_Filename_Sheets,
	DEBUG => True);

our @EXPORT = qw(%Environment);

sub ProcessTFTAutoprobeData() {
	my $Lot_ID = $Environment{'Lot_ID'};
	my @WaferList = $Environment{'Wafer_List'};
	my $Path_To_Data_File = $Environment{'Path_To_Data_File'};
	my $currentPath = "";
	my $DEBUG = $Environment{'DEBUG'};
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
	
	$Environment{'Test_Descriptor_Keys_File'} = prompt("Enter Test Descriptor Keys File or \"(compute)\"");
	
	if ($Environment{'Test_Descriptor_Keys_File'} =~ /\(compute\)/) {
		$UseTestDescriptorKeys = False;
	} else {
		if ($Environment{'Test_Descriptor_Keys_File'} =~ /\s+/) {
			print("Invalid Test Descriptor Keys File");
			return(1);
		}
	}
	
	# Display current analysis setup
	say "Current Setup: ";
	say "Path to Lot: " , $Environment{'Path_To_Data_File'};
	say "Analysi Master File: " , $Environment{'Analysis_Master_Name'};
	say "Test Descriptor Keys File: " , $Environment{'Test_Descriptor_Keys_File'};
	say "Test Name For Processing: " , $Environment{'Test_Name_For_Processing'};
	say "Process Reverse Sweeps?: " , $Environment{'Process_Reverse_Sweeps'};
	say "Append Data to Summary?: " , $Environment{'Append'};
	say "Print Graphs?: " , $Environment{'Print_Graphs'};
	say "Print Graphs to File?: " , $Environment{'Print_Graphs_To_File'};
	say "Delete Summary Filenames?: " , $Environment{'Delete_Summary_Filenames_Sheets'};
	
	if ( (my $continue = prompt("Continue?")) =~ /no|n|No/) {
		return(1);
	}
	
	if ($UseTestDescriptorKeys == True) {
		# We need to read teh TestDesriptorKeys Excel file here;
		my $testIdentifier;
		my $totalSites;
		my $KeyFile;
		my $FullKeyName;
		# First, open the TestDescriptorKeys Workbook and switch to the specified Worksheet
		my $parser = Spreadsheet::ParseExcel->new();
		my $workbook = $parser->parse($Environment{'Test_Descriptor_Keys_File'});
		
		if ( !defiend $workbook ) {
			die $parser->error(), ".\n";
		}
		
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
		if ($Lot_ID =~ /exit|quit|EXIT|QUIT/) {
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
	
	foreach my $wafer (@WaferList) {
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
		seek($f,0,0);
		
		
	
}

sub prompt() {
	my $inStr = shift;

	my $input;
	print($inStr, "\n");
	$input = <STDIN>;
	return($input);
}
	

1;

	
