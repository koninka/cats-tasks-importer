#!/usr/bin/perl

BEGIN { require "utils.pl"; }

use strict;
use warnings;
use lib CATS_DB;
use CATS::DB;
use CATS::BinaryFile;
use Digest::SHA qw(sha1_hex);
use File::stat;
use File::Path;
use XML::LibXML;
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);

no if $] >= 5.018, 'warnings', "experimental::smartmatch";

Archive::Zip::setErrorHandler(sub {});

sub get_xml_from_zip {
   my $zip = Archive::Zip->new();
   $zip->read($_[0]) == AZ_OK or error("can't read");
   my @xml_members = $zip->membersMatching('.*\.xml$');
   error('*.xml not found') if !@xml_members;
   error('found several *.xml in archive') if @xml_members > 1;
   my $member = $xml_members[0];
   $member->desiredCompressionMethod(COMPRESSION_STORED);
   my $status = $member->rewindData();
   $status == AZ_OK or error("code $status");

   my $data = '';
   while (!$member->readIsDone()) {
     (my $buffer, $status) = $member->readChunk();
     $status == AZ_OK || $status == AZ_STREAM_END or error("code $status");
     $data .= $$buffer;
   }
   $member->endRead();
   return $data;
}

CATS::DB::sql_connect;

$dbh->do('DELETE FROM problems');
$dbh->do('DELETE FROM contest_problems');
my $sth = $dbh->prepare(q~
   INSERT INTO problems (id, title, author, zip_archive, hash, upload_date, contest_id, input_file, output_file)
   VALUES (?, ?, ?, ?, ?, current_timestamp, 1,'in','out')~);
my $cp_sth = $dbh->prepare(q~
   INSERT INTO contest_problems(id, problem_id, contest_id) VALUES(?, ?, 1)~);

my @tasks = ();
my @files = map {m|@{[PROBLEMS_DIR]}(.*)|; $1} glob(PROBLEMS_DIR . '*.zip');
# my @files = sort{$files{$a} <=> $files{$b}} keys %files;

my $id_gen++;
foreach my $zip (@files) {
   my $xml_data;
   my $zip_path = PROBLEMS_DIR . $zip;
   eval {
      eval {
         $xml_data = get_xml_from_zip($zip_path);
      };
      if ($@) {
         `echo "y" | zip -F $zip_path --out @{[TMP_ZIP]}`;
         $xml_data = get_xml_from_zip(TMP_ZIP);
         unlink TMP_ZIP;
      }
      my ($el) = XML::LibXML->load_xml(string => $xml_data)->getDocumentElement()->getElementsByTagName('Problem') or error('no Problem');
      my $title = $el->getAttribute('title') or error('No title');
      my $author = '';
      $author = $el->getAttribute('author') if defined $el->getAttribute('author');
      utf8::encode($title);
      utf8::encode($author);
      my $sha1 = sha1_hex($title . $author);
      unless ($sha1 ~~ @tasks) {
         my $data = '';
         CATS::BinaryFile::load($zip_path, \$data) or error("open '$zip_path' failed: $!");
         $zip =~ m/^problem_(.*).zip$/;
         my $pid = new_id;
         $sth->bind_param(1, $pid);
         $sth->bind_param(2, $title);
         $sth->bind_param(3, $author);
         $sth->bind_param(4, $data);
         $sth->bind_param(5, $1);
         $sth->execute;
         if ($title eq 'Космос для школьников' || $title eq "Testlib. Pascal: 1.9; C/C++: 0.3.3, 0.4.3;") {
            $sth->bind_param(1, new_id);
            $sth->bind_param(2, $title);
            $sth->bind_param(3, $author);
            $sth->bind_param(4, $data);
            $sth->bind_param(5, $1);
            $sth->execute;
         }
         $cp_sth->bind_param(1, $id_gen++);
         $cp_sth->bind_param(2, $pid);
         $cp_sth->execute;
         push @tasks, $sha1;
      }
   };
   if ($@) {
      add_failed_zip($zip);
   } else {
      rmtree TMP_ZIP_DIR;
   }
}
$dbh->commit;
CATS::DB::sql_disconnect;

print_failed_zips;