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
   PROBLEMS_DIR   => 'problems',
   DEFAULT_AUTHOR => 'unknown'
};

no if $] >= 5.018, 'warnings', "experimental::smartmatch";

#get vars
my ($test_mode, $encodeToUTF8) = undef, undef;
# my $encodeToUTF8 = undef;

foreach (@ARGV) {
   tr/-//d;
   $test_mode    = $_ eq 't' if !(defined $test_mode    && $test_mode);
   $encodeToUTF8 = $_ eq 'e' if !(defined $encodeToUTF8 && $encodeToUTF8);
}
printf "test mode started\n"      if $test_mode;
printf "recoding files enabled\n" if $encodeToUTF8;

rmtree(REPOS_DIR);
mkdir REPOS_DIR;

#last commit sha1
#git log -1 --pretty=format:%H
# stat -c%y pr/problem_0OfMauOjAaOm6X7o3jHWpQoELt9wrn4K.zip | sed 's/^\([0-9\-]*\) \([0-9:]*\).*/\1 \2/'

my @authors = ();
sub add_author {
   push @authors, $_[0] unless ($_[0] ~~ @authors)
}

my $dir = PROBLEMS_DIR;
my $repos_dir = REPOS_DIR;
my %tasks = ();
my %titles = ();
foreach (glob("$dir/*.zip")) {
   my $zip = $1 if m|$dir/(.*)|;
   next if $zip ~~ undef;
   rmtree('dir');
   my $ae = Archive::Extract->new(archive => "$dir/$zip")->extract(to => 'dir'); #`unzip -a $dir/$zip -d dir`
   my ($f) = glob('dir/*.xml');
   my $xml = XML::LibXML->new()->parse_file($f);
   my $attributes = $xml->getDocumentElement()->getChildrenByTagName("Problem")->item(0)->attributes();
   my $title = $attributes->getNamedItem('title')->value;
   my $author = $attributes->getNamedItem('author')->value;
   add_author($author);
   my $repo_name;
   if (exists($titles{$title})) {
      $repo_name = $titles{$title};
   } else {
      $titles{$title} = $repo_name = $1 if $f =~ m|dir/(.*).xml|;
      mkdir "$repos_dir/$repo_name";
   }
   foreach (glob('dir/*')){
      copy $_, "$repos_dir/$repo_name";
   }
   print `stat -c%y $dir/$zip`;
   last;
   # $task_zip =~ s|problems/||;
   # printf "%s\n", $task_zip;
}