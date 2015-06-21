=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

  Questions may also be sent to the Ensembl help desk at
  <http://www.ensembl.org/Help/Contact>.

=head1 NAME

Bio::EnsEMBL::Hive::RunnableDB::DumpMultiAlign::Readme

=head1 SYNOPSIS

This RunnableDB module is part of the DumpMultiAlign pipeline.

=head1 DESCRIPTION

This RunnableDB module generates a general README.{emf} file and a specific README for the multiple alignment being dumped

=cut


package Bio::EnsEMBL::Compara::RunnableDB::DumpMultiAlign::Readme;

use strict;
use warnings;

use Cwd;
use Text::Wrap;

use Bio::EnsEMBL::Compara::Graph::NewickParser;

use base ('Bio::EnsEMBL::Compara::RunnableDB::BaseRunnable');


sub run {
    my $self = shift;

    #
    #Copy README.{format} to output_dir eg README.emf
    #Currently there is only a README.emf
    #
    my $from = $INC{"Bio/EnsEMBL/Compara/RunnableDB/DumpMultiAlign/Readme.pm"};
    my $format = $self->param('format');
    $from =~ s/Readme\.pm$/README.$format/; 

    my $to = $self->param('output_dir');
    my $cmd = "cp $from $to";

    #Check README file and directory exist (do not for maf)
    if (-e $from && -e $to) { 
	if(my $return_value = system($cmd)) {
	    $return_value >>= 8;
	    die "system( $cmd ) failed: $return_value";
	}
    }

    #Create specific README file
    $self->_create_specific_readme();

}


#
#Internal methods
#

#
#Create specific README file
#
sub _create_specific_readme {
    my ($self) = @_;
    #
    #Load registry
    #
    if ($self->param('reg_conf')) {
	Bio::EnsEMBL::Registry->load_all($self->param('reg_conf'),1);
    } elsif ($self->param('db_url')) {
	my $db_urls = $self->param('db_url');
	foreach my $db_url (@$db_urls) {
	    Bio::EnsEMBL::Registry->load_registry_from_url($db_url);
	}
    } # By default, we expect the genome_dbs to have a locator

    #Note this is using the database set in $self->param('compara_db').
    my $compara_dba = $self->compara_dba;

    #Get method_link_species_set
    my $mlss_adaptor = $compara_dba->get_MethodLinkSpeciesSetAdaptor;
    my $mlss = $mlss_adaptor->fetch_by_dbID($self->param('mlss_id'));

    #If dumping conservation scores, need to find associated multiple alignment
    #mlss
    if (($mlss->method->type) eq "GERP_CONSERVATION_SCORE") {
	$mlss = $mlss_adaptor->fetch_by_dbID($mlss->get_value_for_tag('msa_mlss_id'));
    }

    #Get tree and ordered set of genome_dbs
    my ($newick_species_tree, $species_set) = $self->_get_species_tree($mlss);

    my $filename = $self->param_required('readme_file');
    open my $fh, '>', $filename || die ("Cannot open $filename");
    $self->param('fh', $fh);

    if ($mlss->method->type eq "PECAN") {
	$self->_create_specific_pecan_readme($compara_dba, $mlss, $species_set, $newick_species_tree);
    } elsif ($mlss->method->type eq "EPO") {
	$self->_create_specific_epo_readme($compara_dba, $mlss, $species_set, $newick_species_tree);
    } elsif ($mlss->method->type eq "EPO_LOW_COVERAGE") {
	$self->_create_specific_epo_low_coverage_readme($compara_dba, $mlss, $species_set, $newick_species_tree, $mlss_adaptor);
    } elsif ($mlss->method->type eq "LASTZ_NET") {
	$self->_create_specific_lastz_readme($compara_dba, $mlss, $species_set);
    } else {
        die "I don't know how to generate a README for ".$mlss->method->type."\n";
    }

    close($fh);
}

#
# Get the species tree either from a file or the database. 
# Prune if necessary. 
# Convert genome_db_ids to species names if necessary
# Return species_tree and ordered list of genome_dbs
#
sub _get_species_tree {
    my ($self, $mlss) = @_;

    my $ordered_species;

    #Try to get tree from mlss_tag table
    my $newick_species_tree = $mlss->get_value_for_tag('species_tree');
    
    #If this fails, try to get from file
    if (!$newick_species_tree && $self->param('species_tree_file') ne "") {
        $newick_species_tree = $self->_slurp($self->param('species_tree_file'));
    }

    $newick_species_tree =~ s/^\s*//;
    $newick_species_tree =~ s/\s*$//;
    $newick_species_tree =~ s/[\r\n]//g;

    my $species_tree =
      Bio::EnsEMBL::Compara::Graph::NewickParser::parse_newick_into_tree($newick_species_tree);

    my $genome_dbs = $mlss->species_set_obj->genome_dbs;

    my %leaves_names;
    foreach my $genome_db (@$genome_dbs) {
	my $name = $genome_db->name;
	#$name =~ tr/ /_/;
	next if ($name eq "ancestral_sequences");
	$leaves_names{$genome_db->dbID} = $name;
	$leaves_names{$name} = $genome_db;
    }

    foreach my $leaf (@{$species_tree->get_all_leaves}) {
	my $leaf_name = lc($leaf->name);
	unless (defined $leaves_names{$leaf_name}) {
	    $leaf->disavow_parent;
	    $species_tree = $species_tree->minimize_tree;
	}
	if ($leaf_name =~ /\d+/) {
	    $leaf->name($leaves_names{$leaf_name});
	}
	if (defined $leaves_names{$leaf_name}) {
	    push @$ordered_species, $leaves_names{$leaf_name};
	}
    }
    $newick_species_tree = $species_tree->newick_format("simple");
    return ($newick_species_tree, $ordered_species);
}

#
#Create EPO README file
#
sub _create_specific_epo_readme {
    my ($self, $compara_dba, $mlss, $species_set, $newick_species_tree) = @_;

    $self->_print_header(scalar(@$species_set)."-way Enredo-Pecan-Ortheus (EPO) multiple alignments");
    $self->_print_species_set("The set of species is:", $species_set);
    $self->_print_species_tree($newick_species_tree);

    $self->_print_paragraph("First, Enredo is used to build a set of co-linear regions between the
genomes. Then Pecan aligns these whole set of sequences. Last, Ortheus
uses the Pecan alignments to infer the ancestral sequences.");

    $self->_print_enredo_help();
    $self->_print_pecan_help();
    $self->_print_ortheus_help();
    $self->_print_file_grouping_help();
    $self->_print_helper($mlss);
}

#
#Create EPO_LOW_COVERAGE README file
#
sub _create_specific_epo_low_coverage_readme {
    my ($self, $compara_dba, $mlss, $species_set, $newick_species_tree, $mlss_adaptor) = @_;

    my $high_coverage_mlss = $mlss_adaptor->fetch_by_dbID($mlss->get_value_for_tag('high_coverage_mlss_id'));
    my $high_coverage_species_set = $high_coverage_mlss->species_set_obj->genome_dbs;

    my %high_coverage_species;
    foreach my $species (@$high_coverage_species_set) {
	$high_coverage_species{$species} = 1;
    }

    $self->_print_header(scalar(@$species_set)."-way Enredo-Pecan-Ortheus (EPO) multiple alignments");

    #species_set is ordered so want to print out lists in the correct
    #phylogenetic order
    $self->_print_species_set(
        "The core set of species used for the " . @$high_coverage_species_set . "-way EPO alignment:",
        [grep {defined $high_coverage_species{$_}} @$species_set]);

    $self->_print_species_set(
        "And the extra 2X genomes are:",
        [grep {not defined $high_coverage_species{$_}} @$species_set]);

    $self->_print_species_tree($newick_species_tree);

    my $gdb_grouping = $self->compara_dba->fetch_by_dbID($self->param('genome_db_id'));
    my $species = $self->_get_species_common_name($gdb_grouping);
    $self->_print_paragraph("To build the " . @$high_coverage_species_set . "-way alignment, first, Enredo is used to build a set of
co-linear regions between the genomes and then Pecan aligns these regions. 
Next, Ortheus uses the Pecan alignments to infer the ancestral sequences. Then
the 2X genomes were mapped to the $species sequence using their pairwise 
BlastZ-net alignments. Any insertions in the 2X genomes were removed (ie no 
gaps were introduced into the $species sequence).");

    $self->_print_enredo_help();
    $self->_print_pecan_help();
    $self->_print_ortheus_help();
    $self->_print_gerp_help();
    $self->_print_file_grouping_help();
    $self->_print_helper($mlss);
}

#
#Create PECAN README file
#
sub _create_specific_pecan_readme {
    my ($self, $compara_dba, $mlss, $species_set, $newick_species_tree) = @_;

    $self->_print_header(scalar(@$species_set)."-way Pecan multiple alignments");
    $self->_print_species_set("The set of species was:", $species_set);
    $self->_print_species_tree($newick_species_tree);

    $self->_print_paragraph("First, Mercator is used to build a synteny map between the genomes and then
Pecan builds alignments in these syntenic regions.");

    $self->_print_pecan_help();
    $self->_print_gerp_help();
    $self->_print_file_grouping_help();
    $self->_print_helper($mlss);
}

#
#Create LASTZ_NET README file
#
sub _create_specific_lastz_readme {
    my ($self, $compara_dba, $mlss, $species_set) = @_;

    my $full_pairwise_name = join(' vs ', map {$self->_get_species_description($_)} @$species_set);
    $self->_print_header("$full_pairwise_name LASTZ pairwise alignments");

    my $ref_species = $mlss->get_value_for_tag('reference_species');
    my $ref_genome_db = $self->compara_dba->get_GenomeDBAdaptor->fetch_by_name_assembly($ref_species);
    my $common_species_name = $self->_get_species_common_name($ref_genome_db);
    $self->_print_paragraph("$common_species_name was used as the reference species. After running LastZ, the raw LastZ alignment blocks are chained according to their location in both genomes. During the final netting process, the best sub-chain is chosen in each region on the reference species.");

    $self->_print_file_grouping_help();
    $self->_print_helper($mlss);
}



#### Utils
##############

sub _get_species_common_name {
    my ($self, $genome_db) = @_;
    return $genome_db->db_adaptor->get_MetaContainer->get_common_name;
}

sub _get_species_description {
    my ($self, $genome_db) = @_;
    return sprintf('%s (%s)', $self->_get_species_common_name($genome_db), $genome_db->assembly);
}

sub _print_paragraph {
    my ($self, $text) = @_;
    local $Text::Wrap::columns = 100;
    $self->param('fh')->write( fill('', '', ucfirst $text)."\n\n" );
}

sub _print_line {
    my ($self, $text) = @_;
    $self->param('fh')->write( (ucfirst $text)."\n" );
}

sub _print_species_set {
    my ($self, $intro_text, $set) = @_;
    $self->_print_line($intro_text);
    foreach my $species (@$set) {
        $self->_print_line($self->_get_species_description($species));
    }
    $self->_print_line("");
}

sub _print_species_tree {
    my ($self, $newick_species_tree) = @_;
    $newick_species_tree =~ s/\(/(\n/g;
    $newick_species_tree =~ s/,/,\n/g;
    $self->_print_line("The species tree was:");
    $self->_print_line($newick_species_tree);
    $self->_print_line("\n");
}

## Shared pieces of text
##########################

sub _print_enredo_help {
    my ($self) = @_;
    $self->_print_paragraph("Enredo is a graph-based method. The initial graph is built from a mapping of
a set of anchors on every genome. Note that each anchor can map several times
on a single genome. Enredo uses this information to define co-linear regions.
Read more about Enredo: http://www.ebi.ac.uk/~jherrero/downloads/enredo/");
}

sub _print_pecan_help {
    my ($self) = @_;
    $self->_print_paragraph("Pecan is a global multiple sequence alignment program that makes practical
the probabilistic consistency methodology for significant numbers of
sequences of practically arbitrary length. As input it takes a set of
sequences and a phylogenetic tree. The parameters and heuristics it employs
are highly user configurable, it is written entirely in Java and also
requires the installation of Exonerate.
Read more about Pecan: http://github.com/benedictpaten/pecan");
}

sub _print_ortheus_help {
    my ($self) = @_;
    $self->_print_paragraph("Ortheus is a probabilistic method for the inference of ancestor (a.k.a tree)
alignments. The main contribution of Ortheus is the use of a phylogenetic
model incorporating gaps to infer insertion and deletion events.
Read more about Ortheus: http://github.com/benedictpaten/ortheus");
}

sub _print_gerp_help {
    my ($self) = @_;
    $self->_print_paragraph("GERP scores the conservation of each position in the alignment and defines
constrained elements based on these conservation scores.
Read more about Gerp: http://mendel.stanford.edu/SidowLab/downloads/gerp/index.html");
}

sub _print_file_grouping_help {
    my ($self) = @_;
    my $gdb_grouping = $self->compara_dba->get_GenomeDBAdaptor->fetch_by_dbID($self->param('genome_db_id'));
    my $common_species_name = $self->_get_species_common_name($gdb_grouping);

    my @par = ();
    if ($self->param('mode') ne 'file') {
        push @par, "Alignments are grouped by $common_species_name chromosome.";
        push @par, "Alignments containing duplications in $common_species_name are dumped once per duplicated segment.";
        push @par, "The files named *.other*." . $self->param('format') . "contain alignments that do not include any $common_species_name region.";
    }
    if ($self->param('split_size')) {
        push @par, "Each file contains up to " . $self->param('split_size') . " alignments.";
    }
    $self->_print_paragraph(join(" ", @par));
}

sub _print_header {
    my ($self, $title) = @_;
    my $schema_version = $self->compara_dba->get_MetaContainer->get_schema_version();
    $self->_print_paragraph("This directory contains all the $title corresponding
to Release $schema_version of Ensembl (see http://www.ensembl.org for further details
and credits about the Ensembl project).");
}

sub _print_helper {
    my ($self, $mlss) = @_;
    if ($self->param('format') eq 'emf') {
        $self->_print_paragraph("An emf2maf parser is available with the ensembl compara API, in the
scripts/dumps directory. Alternatively you can download it using the GitHub frontend:
https://github.com/Ensembl/ensembl-compara/raw/master/scripts/dumps/emf2maf.pl");
    } elsif ($self->param('format') eq 'maf') {
        $self->_print_paragraph("Please note that MAF format does not support conservation scores.") if ($mlss->method->type eq 'EPO_LOW_COVERAGE') or ($mlss->method->type eq 'PECAN');
    }
}

1;
