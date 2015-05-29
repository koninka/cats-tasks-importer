#!/usr/bin/perl

BEGIN {
   require "utils.pl";
}

use strict;
use warnings;


use lib CATS_DB;
use CATS::DB;
use CATS::BinaryFile;
use CATS::Problem;
use CATS::Problem::Repository;

use Data::Dumper;
use File::Path;
use File::Spec;
use Data::Dumper;
use Archive::Zip qw( :ERROR_CODES );

rmtree ADDITIONAL_ZIP_DIR;

CATS::DB::sql_connect;
my $ary_ref = $dbh->selectall_arrayref("SELECT id, repo, commit_sha, zip_archive FROM problems ORDER BY id ASC");
$dbh->commit;

open my $fh, '>', MISSED_FOLDER_FNAME or die 'cannot open > ' . MISSED_FOLDER_FNAME . ': $!';
mkdir ADDITIONAL_ZIP_DIR;
foreach (@$ary_ref) {
   rmtree TMP_ZIP_DIR;
   mkdir TMP_ZIP_DIR;

   my ($id, $repo_id, $commit_sha, $zip_data) = @$_;

   $repo_id //= '';
   ($repo_id, $commit_sha) = $repo_id =~ /^\d+$/ ? ($repo_id, $commit_sha) : ($id, '');

   # warn Dumper($id, $repo_id, $commit_sha);

   print "Work with $id problem... ";

   my $repo_folder = File::Spec->catfile(REPOS_DIR, $repo_id);
   if (!-d $repo_folder) {
      print "Repository ($repo_folder) for $id in doesn't exist!\n";
      next;
   }
   if (!$zip_data) {
      print "Empty zip archive for $id problem\n";
      next;
   }
   my $repo = CATS::Problem::Repository->new(dir => File::Spec->catdir(REPOS_DIR, $repo_id) . '/');
   eval {
      my $zip_name =  File::Spec->catfile(ADDITIONAL_ZIP_DIR, "problem_$id.zip");
      CATS::BinaryFile::save($zip_name, $zip_data);
      extract_zip($zip_name);
      opendir my $dh, TMP_ZIP_DIR or die "Cannot open dir: $!";
      $commit_sha = $repo->get_latest_master_sha if !$commit_sha || $commit_sha eq '';
      my $folders = '';
      my $entries = $repo->tree($commit_sha)->{entries};
      # die Dumper($entries);
      while (my $file = readdir $dh) {
         next if $file =~ /^\.+$/ || !-d File::Spec->catfile(TMP_ZIP_DIR, $file);
         my $exist = 0;
         for my $repo_file (@$entries) {
            $exist ||= $repo_file->{file_name} eq $file;
         }
         if (!$exist) {
            print "Repository for problem $id is not correctly... " if $folders eq '';
            $folders .= "\t$file";
         }
      }
      print $fh "$id\t$folders\n" if $folders ne '';
   };
   if ($@) {
      print "Error occured while parse $id problem: $@\n";
      next;
   }
   print "Done\n";
}

close $fh;

1;
