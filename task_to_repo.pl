#!/usr/bin/perl

BEGIN {
   require "utils.pl";
   require "authors.pl";
}

use strict;
use warnings;
use lib CATS_DB;
use CATS::DB;
use File::Path;
use File::Copy;
use File::stat;
use XML::LibXML;
use Git::Repository;
use Archive::Zip qw( :ERROR_CODES );
use constant LIST_PROCESSING => 'list_proc.txt';
use Data::Dumper;

our %authors_map;

Archive::Zip::setErrorHandler(sub {});

no if $] >= 5.018, 'warnings', "experimental::smartmatch";

#-----------------------------------------------------------------
#-----------------SCRIPT OPTIONS AND PREPARATION------------------
#-----------------------------------------------------------------
my ($DEBUG, $encodeToUTF8, $needAuthorTable, $proceedHandle) = undef, undef, undef, undef;

foreach (@ARGV) {
   tr/-//d;
   $DEBUG           = $_ eq 't' if !(defined $DEBUG           && $DEBUG);
   $encodeToUTF8    = $_ eq 'e' if !(defined $encodeToUTF8    && $encodeToUTF8);
   $proceedHandle   = $_ eq 'p' if !(defined $proceedHandle   && $proceedHandle);
   $needAuthorTable = $_ eq 'a' if !(defined $needAuthorTable && $needAuthorTable);
}
printf "DEBUG STARTED\n"                        if $DEBUG;
printf "recoding files enabled\n"               if $encodeToUTF8;
printf "PARSE AUTHORS TO authors.txt STARDER\n" if $needAuthorTable;
if ($proceedHandle) {
   print "continue files processing\n";
} else {
   print "start from the beginning files processing\n";
   rmtree REPOS_DIR;
}

rmtree XMLS_DIR;
rmtree TMP_ZIP_DIR;
unlink TMP_ZIP;

my @authors = ();
sub add_author {
   if ($_[0] ne "" || $_[0] ne DEFAULT_AUTHOR) {
      push @authors, $_[0] unless ($_[0] ~~ @authors)
   }
}

sub extract_zip {
   my $zip = Archive::Zip->new();
   $zip->read($_[0]) == AZ_OK or error("can't read");
   my @xml_members = $zip->membersMatching('.*\.xml$');
   error('*.xml not found') if !@xml_members;
   error('found several *.xml in archive') if @xml_members > 1;
   $zip->extractTree('', TMP_ZIP_DIR) == AZ_OK or error("can't extract");
}

my %titles_id = ();
my %id_titles = ();

my %zip_files = map {m|@{[PROBLEMS_DIR]}/(.*)|; $1 => stat($_)->mtime} glob(PROBLEMS_DIR . '/*.zip');
my @zip_files = sort{$zip_files{$a} <=> $zip_files{$b}} keys %zip_files;

#-----------------------------------------------------------------
#----------------------RENAMES DETERMINATION----------------------
#-----------------------------------------------------------------
goto REPOSITORY_CREATION if $needAuthorTable;

mkdir XMLS_DIR;
Git::Repository->run(init => XMLS_DIR);
my $xml_repo = Git::Repository->new(
   work_tree => XMLS_DIR,
   {
      env => {
         GIT_AUTHOR_NAME  => DEFAULT_AUTHOR,
         GIT_AUTHOR_EMAIL => DEFAULT_EMAIL
      }
   }
);
CATS::DB::sql_connect;
my $sth = $dbh->prepare('SELECT id FROM problems WHERE title=? ORDER BY id');
open FILE, ">zip_xml.txt" or die $! if $DEBUG;
foreach my $zip (@zip_files) {
   my $zip_path = PROBLEMS_DIR . "/$zip";
   eval {
      eval {
         extract_zip($zip_path);
      };
      if ($@) {
         `echo "y" | zip -F $zip_path --out @{[TMP_ZIP]}`;
         extract_zip(TMP_ZIP);
         unlink TMP_ZIP;
      }
      my ($xml_file) = glob(TMP_ZIP_DIR . '/*.xml');
      my ($el) = XML::LibXML->load_xml(location => $xml_file)->getDocumentElement()->getElementsByTagName('Problem');
      my $title = $el->getAttribute('title');
      # utf8::encode($title);
      unless (exists $titles_id{$title}) {
         $sth->bind_param(1, $title);
         $sth->execute;
         my $aref = $sth->fetchall_arrayref;
         error("Task's record for $title doesn't exist in the database") if !@$aref;
         $titles_id{$title} = $aref->[0][0];
         $id_titles{$titles_id{$title}} = $title;
         print FILE "$zip $titles_id{$title}\n" if $DEBUG;
         copy $xml_file, "@{[XMLS_DIR]}/$titles_id{$title}.xml";
         $xml_repo->run(add => '.');
         $xml_repo->run(commit => '-m', "Add $titles_id{$title}");
         $dbh->commit;
         error("There is more than one record for $title") if @$aref > 1;
      }
   };
   if ($@) {
      add_failed_zip($zip);
   } else {
      rmtree TMP_ZIP_DIR;
   }
}
close FILE if $DEBUG;
$sth->finish;
CATS::DB::sql_disconnect;

print_failed_zips;

my @log = $xml_repo->run(log => '--diff-filter=C', '-C', "-C@{[SIMILARITY_INDEX]}%", '--summary', '--format="% "');
@log = reverse map {m/([0-9]+)\.xml => ([0-9]+)\.xml \(([0-9]+)%\)/; {old_name => $1, new_name => $2, sidx => $3}} grep {/^ copy/} @log;

my %renamings = ();    #choose from several alternatives that renaming which has the highest similarity index
for my $i (0..$#log) {
   my $h = $log[$i];
   for my $j ($i+1..$#log) {
      if (($log[$i]->{old_name} eq $log[$j]->{old_name}) && ($log[$i]->{sidx} < $log[$j]->{sidx})) {
         $h = $log[$j];
         $log[$i] = $log[$j];
      }
   }
   $renamings{$h->{new_name}} = $h->{old_name};
}

if ($DEBUG) {
   print "$_ <= $renamings{$_}\n" foreach keys %renamings;
}

my @base_tasks_to_be_renamed = ();
foreach (keys %renamings) {
   $_ = $renamings{$_} while defined $renamings{$_};
   next if $_ ~~ @base_tasks_to_be_renamed;
   push @base_tasks_to_be_renamed, $_;
}

#-----------------------------------------------------------------
#------------------REPOSITORY CREATION FOR TASKS------------------
#-----------------------------------------------------------------
REPOSITORY_CREATION:
mkdir REPOS_DIR if !$needAuthorTable;
my @reps = ();
my @renamed_tasks = ();
foreach my $zip (@zip_files) {
   my $zip_path = PROBLEMS_DIR . "/$zip";
   # print "handle $zip\n" if $DEBUG;
   # eval {
      eval {
         extract_zip($zip_path);
      };
      if ($@) {
         `echo "y" | zip -F $zip_path --out @{[TMP_ZIP]}`;
         extract_zip(TMP_ZIP);
         unlink TMP_ZIP;
      }
      my ($xml_file) = glob(TMP_ZIP_DIR . '/*.xml');
      my ($el) = XML::LibXML->load_xml(location => $xml_file)->getDocumentElement()->getElementsByTagName('Problem');
      my $title = $el->getAttribute('title');
      # utf8::encode($title);
      $_ = $el->getAttribute('author') if defined $el->getAttribute('author');
      $_ = DEFAULT_AUTHOR if $_ ~~ undef || $_ eq '';
      # utf8::encode($_);
      add_author($_);
      $_ = (split ',')[0];
      s/\(.*\)//;
      s/^\s*(.*?)\s*$/$1/;
      my $author = $_;
      goto END_EVAL if $needAuthorTable || !(exists $titles_id{$title} && defined $titles_id{$title});
      my $task_id = $titles_id{$title};
      my $repo_path = "@{[REPOS_DIR]}/$task_id";
      my $commit_msg = 'Change task';
      my $xml_id = $task_id;
      my $already_has_rep = 0;
      if (exists $renamings{$task_id}) {
         $already_has_rep = 1;
         unless ($task_id ~~ @renamed_tasks) {
            push @renamed_tasks, $task_id;
            $commit_msg = "Rename task from '$id_titles{$renamings{$task_id}}' to '$id_titles{$task_id}'";
         }
         $task_id = $renamings{$task_id} while defined $renamings{$task_id};
         $repo_path = "@{[REPOS_DIR]}/$task_id";
      } elsif ($task_id ~~ @reps) {
         $already_has_rep = $task_id ~~ @base_tasks_to_be_renamed;
      } else {
         $commit_msg = 'Initial commit';
         push @reps, $task_id;
         mkdir $repo_path;
         Git::Repository->run(init => $repo_path);
      }
      my $repo = Git::Repository->new(
         work_tree => $repo_path,
         {
            env => {
               GIT_AUTHOR_NAME  =>
                     exists $authors_map{$author}
                  ?  (
                        exists $authors_map{$author}{git_author}
                      ? $authors_map{$author}{git_author}
                      : $author
                     )
                  : EXTERNAL_AUTHOR,
               GIT_AUTHOR_EMAIL => exists $authors_map{$author} ? $authors_map{$author}{email} : DEFAULT_EMAIL
            }
         }
      );
      $repo->run(rm => '*', '--ignore-unmatch');
      # $repo->run(rm => '*.xml') if $already_has_rep;
      foreach (glob(TMP_ZIP_DIR . '/*')) {
         # if ($_ eq $xml_file) {
            # copy $_, "$repo_path/${xml_id}.xml";
         # } else {
            copy $_, $repo_path;
         # }
      }
      $repo->run(add => '-A');
      $repo->run(commit => '-m', $commit_msg, sprintf('--date=%s', stat($zip_path)->mtime));
      END_EVAL:
   # };
   if ($@) {
      print "$@\n";
      add_failed_zip($zip);
   } else {
      rmtree TMP_ZIP_DIR;
   }
}

# foreach (@authors) {
#    print "true - $_\n" if utf8::is_utf8($_);
# }

if ($needAuthorTable) {
   open FILE, '>authors.txt' or die $!;
   foreach (sort @authors) {
      utf8::encode($_);
      print FILE "$_\n";
   }
   close FILE;
}
