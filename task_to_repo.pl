#!/usr/bin/perl

use strict;
use warnings;
# use diagnostics;
use File::Path;
use File::Copy;
use File::stat;
use XML::LibXML;
use Git::Repository;
use Archive::Zip qw( :ERROR_CODES );
# use XML::LibXML::Common;
# use XML::NamespaceSupport;
# use XML::SAX;
use Data::Dumper;
use constant {
   TMP_ZIP        => 'tmp_zip.zip',
   REPOS_DIR      => 'tasks_rep',
   TMP_ZIP_DIR    => 'dir',
   PROBLEMS_DIR   => 'prs',
   DEFAULT_AUTHOR => 'unknown'
};

Archive::Zip::setErrorHandler(sub {});

no if $] >= 5.018, 'warnings', "experimental::smartmatch";

#get vars
my ($debug, $encodeToUTF8, $needAuthorTable) = undef, undef, undef;

foreach (@ARGV) {
   tr/-//d;
   $debug       = $_ eq 't' if !(defined $debug       && $debug);
   $encodeToUTF8    = $_ eq 'e' if !(defined $encodeToUTF8    && $encodeToUTF8);
   $needAuthorTable = $_ eq 'a' if !(defined $needAuthorTable && $needAuthorTable);
}
printf "debug started\n"                    if $debug;
printf "recoding files enabled\n"               if $encodeToUTF8;
printf "parse authors to authors.txt started\n" if $needAuthorTable;

rmtree(REPOS_DIR);
mkdir REPOS_DIR;

#last commit sha1
#git log -1 --pretty=format:%H
# stat -c%y pr/problem_0OfMauOjAaOm6X7o3jHWpQoELt9wrn4K.zip | sed 's/^\([0-9\-]*\) \([0-9:]*\).*/\1 \2/'

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
   $zip->extractTree('', 'dir/') == AZ_OK or error("can't extract");
}

my $error;
sub error {
   $error = $_[0];
   die;
}

my $dir = PROBLEMS_DIR;
my $tmp_zip = TMP_ZIP;
my $tmp_dir = TMP_ZIP_DIR;
my $repos_dir = REPOS_DIR;
my %tasks = ();
my %titles = ();
my @failed_zips = ();

my %files = map {m|$dir/(.*)|; $1 => stat($_)->mtime} glob("$dir/*.zip");
my @files = sort{$files{$a} <=> $files{$b}} keys %files;

# foreach my $keys (sort{$files{$a} <=> $files{$b}} keys %files) {
#    print "$keys\t", scalar localtime($files{$keys}), "\n";
# }

foreach my $zip_name (@files) {
   print "zip = $zip_name, \n" if $debug;
   rmtree(TMP_ZIP_DIR);
   eval {
      eval {
         extract_zip("$dir/$zip_name");
      };
      if ($@) {
         unlink $tmp_zip;
         `echo "y" | zip -F $dir/$zip_name --out $tmp_zip`;
         extract_zip($tmp_zip);
      }
      my ($f) = glob('dir/*.xml');
      my $xml = XML::LibXML->new()->parse_file($f);
      my $attributes = $xml->getDocumentElement()->getChildrenByTagName("Problem")->item(0)->attributes();
      my $title = $attributes->getNamedItem('title')->value if defined $attributes->getNamedItem('title');
      my $author = $attributes->getNamedItem('author')->value if defined $attributes->getNamedItem('author');
      $author = DEFAULT_AUTHOR if $author ~~ undef || $author eq "";
      utf8::encode($author);
      add_author($author);
      # if (!$needAuthorTable) {
      #    my $repo_path;
      #    if (exists($titles{$title})) {
      #       $repo_path = $titles{$title};
      #    } else {
      #       $titles{$title} = $repo_path = "$repos_dir/$1" if $f =~ m|dir/(.*).xml|;
      #       mkdir $repo_path;
      #       Git::Repository->run(init => $repo_path);
      #    }
      #    print "author = $author\n" if $test_mode;
      #    my $repo = Git::Repository->new(
      #       work_tree => $repo_path,
      #       {
      #          env => {
      #             GIT_AUTHOR_NAME  => $author,
      #             GIT_AUTHOR_EMAIL => 'some@mail.ru'
      #          }
      #       }
      #    );
      #    foreach (glob('dir/*')){
      #       copy $_, $repo_path;
      #    }
      #    $repo->run(add => '.');
      #    $repo->run(commit => '-m', 'Initial commit', sprintf("--date=%s", stat("$dir/$zip_name")->mtime));
      # }
      #===================================================
      # print scalar localtime stat("$dir/$zip_name")->mtime;
      # print "\n";
      # print `stat -c%y $dir/$zip_name`;
      # print "\n";
      # last;
      # $task_zip =~ s|problems/||;
      # printf "%s\n", $task_zip;
   };
   if ($@) {
      push @failed_zips, {zip => $zip_name, msg => $error};
   }
}

sub print_res {
   if (scalar @{$_[1]} > 0) {
      $, = "\n";
      print "=======$_[0]=======\n";
      print @{$_[1]};
      print "\n";
   } else {
      print "$_[0] is empty\n";
   }
}

@authors = sort @authors;
print_res("authors name", \@authors);

open FILE, ">authors.txt" or die $!;
foreach (@authors) {
   print FILE "$_\n";
}
close FILE;

print "=======failed zips=======\n";
foreach (@failed_zips) {
   print "$_->{zip} - $_->{msg}\n";
}