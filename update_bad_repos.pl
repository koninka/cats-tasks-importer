#!/usr/bin/perl

BEGIN {
   require "utils.pl";
}

use strict;
use warnings;


use lib CATS_DB;
use CATS::DB;
use CATS::BinaryFile;
use CATS::Problem::Repository;

use XML::LibXML;
use Git::Repository;
use File::Copy::Recursive qw(dircopy);
use File::Path;
use File::Spec;
use Data::Dumper;
use Archive::Zip qw( :ERROR_CODES );

CATS::DB::sql_connect;
my $ary_ref = $dbh->selectall_arrayref("SELECT id, repo, commit_sha FROM problems ORDER BY id ASC");
$dbh->commit;

my $problems = {};
for (@$ary_ref) {
   my ($id, $repo, $commit_sha) = @$_;
   $problems->{$id} = {repo => $repo, sha => $commit_sha // ''};
}

my $query = $dbh->prepare('UPDATE problems SET repo = NULL, commit_sha = NULL WHERE id = ?');
die 'Missed ' . MISSED_FOLDER_FNAME . ' file' unless -e MISSED_FOLDER_FNAME;
open my $fh, '<', MISSED_FOLDER_FNAME or die 'cannot open > ' . MISSED_FOLDER_FNAME . ': $!';
while (my $line = <$fh>) {
   chomp $line;
   my ($id, @folders) = split "\t", $line;
   @folders = grep { $_ ne ''; } @folders;
   print "Handle $id problem... ";
   unless (@folders) {
      print "No folder for $id problem\n";
      next;
   }
   unless (defined $problems->{$id}) {
      print "Not existing problem $id";
      next;
   }
   my ($repo_id, $commit_sha) = $problems->{$id}{repo} =~ /^\d+$/ ? ($problems->{$id}{repo}, $problems->{$id}{sha}) : ($id, '');
   unless (-d File::Spec->catdir(REPOS_DIR, $repo_id)) {
      print "Repository for $id in doesn't exist!\n";
      next;
   }

   my $zip_name =  File::Spec->catfile(ADDITIONAL_ZIP_DIR, "problem_$id.zip");
   my $repo = CATS::Problem::Repository->new(
      dir => File::Spec->catdir(REPOS_DIR, $id) . '/',
      author_name => 'M. Tertishniy',
      author_email => 'mtertishniy@gmail.com'
   );
   eval {
      die "$zip_name doesn't exist!" unless -e $zip_name;
      rmtree TMP_ZIP_DIR;
      mkdir TMP_ZIP_DIR;
      extract_zip($zip_name);
      my $repo_folder = File::Spec->catdir(REPOS_DIR, $id) . '/';
      my $repo = CATS::Problem::Repository->new(
         dir => $repo_folder,
         author_name => 'M. Tertishniy',
         author_email => 'mtertishniy@gmail.com'
      );
      if ($repo_id != $id) {
         $repo->move_history(from => File::Spec->catdir(REPOS_DIR, $repo_id), sha => $commit_sha);
      }

      print "\n";
      for my $folder (@folders) {
         print "\tCopy $folder\n";
         File::Spec->catfile(TMP_ZIP_DIR, $folder);
         my $from = File::Spec->catdir(TMP_ZIP_DIR, $folder);
         my $to = File::Spec->catdir($repo_folder, $folder);
         dircopy($from, $to) or die "Can't copy from $from to $to: $!";
      }
      $repo->add()->commit('', "Add missing folders\n\nIt was lost when moving history", 0);
      $query->bind_param(1, $id);
      $query->execute;
   };
   if ($@) {
      print "Error occured while handling $id problem: $@\n";
      next;
   }
   print "Done\n";
}
$dbh->commit;
close $fh;

1;
