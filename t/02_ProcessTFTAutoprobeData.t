#!/usr/bin/env perl
use Modern::Perl;
use Test;

BEGIN { plan tests => 3, todo => [1, 2, 3] }

# load your module...
use ETest;

# Helpful notes. All note-lines must start with a "#".
print "# Testing ProcessTFTAutoprobeData\n";

%Environment{'Test_Descriptor_Keys_File'} = "(compute)";
%Environment{'Path_To_Data_File'} = "./";
%Environment{'Analysis_Master_Name'} = "Default";
%Environment{'Test_Name_For_Processing'} = "COW";
%Environment{'Process_Reverse_Sweeps'} = True;
%Environment{'Append'} = False;
%Environment{'Print_Graphs'} = False;
%Environment{'Print_Graphs_To_File'} = False;
%Environment{'Delete_Summary_Filenames_Sheets'} = False;


