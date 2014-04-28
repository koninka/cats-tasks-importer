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
   TMP_ZIP         => 'tmp_zip.zip',
   REPOS_DIR       => 'tasks_rep',
   TMP_ZIP_DIR     => 'dir',
   PROBLEMS_DIR    => 'problems',
   KLENINS_EMAIL   => 'klenin@gmail.com',
   DEFAULT_EMAIL   => 'unknown@example.com',
   DEFAULT_AUTHOR  => 'Unknown Author',
   EXTERNAL_AUTHOR => 'external'
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

sub make_author_info {
   my $h = {@_};
   my $res = {email => (defined $h->{email} ? $h->{email} : DEFAULT_EMAIL)};
   $res->{git_author} = $h->{git_author} if defined $h->{git_author};
   return $res;
}

my %authors_map = (
   'A. Klenin'           => make_author_info(email => KLENINS_EMAIL),
   'А. Zhuplev'          => make_author_info(git_author => 'A. Zhuplev'),
   'A. Zhuplev'          => make_author_info,
   'A. Maksimov'         => make_author_info,
   'Andrew Stankevich'   => make_author_info(git_author => 'A. Stankevich'),
   'B. Vasilyev'         => make_author_info,
   'D. Vikharev'         => make_author_info,
   'E. Vasilyeva'        => make_author_info,
   'Elena Kryuchkova'    => make_author_info(git_author => 'E. Kryuchkova'),
   'Georgiy Korneev'     => make_author_info(git_author => 'G. Korneev'),
   'I. Ludov'            => make_author_info,
   'I. Tuphanov'         => make_author_info,
   'I. Tufanov'          => make_author_info(git_author => 'I. Tuphanov'),
   'I. Burago'           => make_author_info,
   'Ludov I. Y.'         => make_author_info(git_author => 'I. Ludov'),
   'Michail Mirzayanov'  => make_author_info(git_author => 'M. Mirzayanov'),
   'Nick Durov'          => make_author_info(git_author => 'N. Durov'),
   'T.Chistyakov'        => make_author_info,
   'T. Chistyakov'       => make_author_info,
   'Roman Elizarov'      => make_author_info(git_author => 'R. Elizarov'),
   'А. Жуплев'           => make_author_info,
   'А. Зенкина'          => make_author_info,
   'А.Кленин'            => make_author_info(email => KLENINS_EMAIL, git_author => 'А. Кленин'),
   'А. Кленин'           => make_author_info(email => KLENINS_EMAIL),
   'Александр С. Кленин' => make_author_info(email => KLENINS_EMAIL, git_author => 'A. Кленин'),
   'А. Шавлюгин'         => make_author_info,
   'В. Гринько'          => make_author_info,
   'В. Кевролетин'       => make_author_info,
   'В. Машенцев'         => make_author_info,
   'В. Степанец'         => make_author_info,
   'Г. Гренкин'          => make_author_info,
   'Е. Васильева'        => make_author_info,
   'Е. Иванова'          => make_author_info,
   'И. Бураго'           => make_author_info,
   'И. Лудов'            => make_author_info,
   'И. Олейников'        => make_author_info,
   'И. Туфанов'          => make_author_info,
   'Кленин А.'           => make_author_info(email => KLENINS_EMAIL, git_author => 'А. Кленин'),
   'Кленин А.С.'         => make_author_info(email => KLENINS_EMAIL, git_author => 'А. Кленин'),
   'Кленина Н. В.'       => make_author_info(git_author => 'Н. Кленина'),
   'М. Спорышев'         => make_author_info,
   'Н.В. Кленина'        => make_author_info(git_author => 'Н. Кленина'),
   'Н. В. Кленина'       => make_author_info(git_author => 'Н. Кленина'),
   'Н. Кленина'          => make_author_info(git_author => 'Н. Кленина'),
   'Н. Чистякова'        => make_author_info,
   'О. Бабушкин'         => make_author_info,
   'О.Ларькина'          => make_author_info(git_author => 'О. Ларькина'),
   'О. Ларькина'         => make_author_info,
   'О. Туфанов'          => make_author_info,
   'С. Пак'              => make_author_info,
   'C. Пак'              => make_author_info,
   'Туфанов И.'          => make_author_info(git_author => 'И. Туфанов'),
);

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
      $_ = $attributes->getNamedItem('author')->value if defined $attributes->getNamedItem('author');
      $_ = DEFAULT_AUTHOR if $_ ~~ undef || $_ eq "";
      utf8::encode($_);
      add_author($_);
      $_ = (split ',')[0];
      s/\(.*\)//;
      s/^\s*(.*?)\s*$/$1/;
      my $author = $_;
      if ($debug) {
         if (exists $authors_map{$author}) {
            print "Author $author exist\n";
         } else {
            print "Author $author don't exist\n";
         }
      }
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