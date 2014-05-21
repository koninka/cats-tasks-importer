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
use Digest::SHA qw(sha1_hex);
use Git::Repository;
use Archive::Zip qw( :ERROR_CODES );
use constant {
   LOG_FILE =>  'log',
   ERROR_V_DEL =>'----------------------------------------------------------------------------------------------------------------------------',
   LIST_PROCESSING => 'list_proc.txt'
};
use Data::Dumper;

our %authors_map;

Archive::Zip::setErrorHandler(sub {});

no if $] >= 5.018, 'warnings', "experimental::smartmatch";

#-----------------------------------------------------------------
#-----------------SCRIPT OPTIONS AND PREPARATION------------------
#-----------------------------------------------------------------
my %keys;
@keys{@ARGV} = undef;
my $DEBUG =  exists $keys{'-t'};
my $needAuthorTable = exists $keys{'-a'};

printf "DEBUG STARTED\n"                        if $DEBUG;
printf "PARSE AUTHORS TO authors.txt STARDER\n" if $needAuthorTable;

rmtree XMLS_DIR;
rmtree REPOS_DIR;
rmtree TMP_ZIP_DIR;
unlink TMP_ZIP;

my @authors = ();
sub add_author {
   if ($_[0] ne "" || $_[0] ne DEFAULT_AUTHOR) {
      push @authors, $_[0] unless ($_[0] ~~ @authors)
   }
}

sub get_zip_hash {
   my @m = $_[0] =~ /_([a-zA-Z0-9])*\.zip$/;
   print @m;
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

my %zip_files = map {m|@{[PROBLEMS_DIR]}(.*)|; $1 => stat($_)->mtime} glob(PROBLEMS_DIR . '*.zip');
my @zip_files = sort{$zip_files{$a} <=> $zip_files{$b}} keys %zip_files;

#-----------------------------------------------------------------
#----------------------------FIX ZIPS-----------------------------
#-----------------------------------------------------------------
# my %fixed_zips = ();
# foreach my $zip_name (@zip_files) {
#    my $zip_path = PROBLEMS_DIR . "/$zip_name";
#    if (Archive::Zip->new()->read($zip_path) != AZ_OK) {
#       set_error("can't read");
#       add_failed_zip($zip_name);
#    }
# }

# my %fixed_zips = ();
# foreach my $zip_name (@zip_files) {
#    my $zip_path = PROBLEMS_DIR . "/$zip_name";
#    if (Archive::Zip->new()->read($zip_path) != AZ_OK) {
#       my $zip_fixed_path = $zip_path;
#       $zip_fixed_path =~ s/([a-zA-Z0-9]+)(\.zip)$/$1_fixed$2/;
#       `echo "y" | zip -F $zip_path --out $zip_fixed_path`;
#       print "$zip_fixed_path\n";
#       if (Archive::Zip->new()->read($zip_fixed_path) == AZ_OK) {
#          print "$zip_fixed_path\n";
#          $fixed_zips{$zip_name} = 1;
#       } else {
#          # unlink $zip_fixed_path;
#          set_error("can't read");
#          add_failed_zip($zip_fixed_path);
#       }
#    }
# }

#-----------------------------------------------------------------
#----------HISTORY CREATION (WITH RENAMES DETERMINATION)----------
#-----------------------------------------------------------------
goto REPOSITORY_CREATION if $needAuthorTable;
my %edges = ();
my %sha_zip = ();
my %zip_sha = ();
my @start_v = ();
my %reverse_renamings = ();

sub add_to_sha_zip {
   my ($zip, $sha) = @_;
   if (defined $sha_zip{$sha} && @{$sha_zip{$sha}} > 0) {
      push @{$sha_zip{$sha}}, $zip;
   } else {
      $sha_zip{$sha} = [$zip];
   }
   $zip_sha{$zip} = $sha;
}

sub add_start_v {
   my ($zip, $sha) = @_;
   push @start_v, {zip => $zip, title => $sha};
   add_to_sha_zip($zip, $sha);
}

sub get_leaf {
   (my $zip) = @_;
   $zip = $edges{$zip}{zip} while exists $edges{$zip};
   return $zip;
}

sub good_add_edge {
   (my $zip, my $sha1, my $sha2) = @_;
   my $idx;
   for (my $i = 0; $i < @{$sha_zip{$sha1}}; $i++) {
      my $leaf = get_leaf($sha_zip{$sha1}[$i]);
      if ($zip_sha{$leaf} eq $sha1) {
         $edges{$leaf} = {zip => $zip, title => $sha2};
         $idx = $i;
         last;
      }
   }
   $sha_zip{$sha1}[$idx] = $zip if $sha1 eq $sha2 && defined $idx;
   $reverse_renamings{$sha2} = $sha1 if $sha1 ne $sha2 && defined $idx && !exists $reverse_renamings{$sha2};
   add_start_v($zip, $sha2) if $idx ~~ undef;
   $zip_sha{$zip} = $sha2;
}

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
foreach my $zip (@zip_files) {
   next if exist_failed_zip($zip);
   my $zip_path = PROBLEMS_DIR . $zip;
   eval {
      extract_zip($zip_path);
      my ($xml_file) = glob(TMP_ZIP_DIR . '*.xml');
      my $xml;
      eval { $xml = XML::LibXML->load_xml(location => $xml_file); };
      error('corrupt xml file') if $@;
      my ($el) = $xml->getDocumentElement()->getElementsByTagName('Problem');
      my $title = $el->getAttribute('title');
      utf8::encode($title);
      # my $sha1 = $title;
      my $sha1 = sha1_hex($title);
      if (-e XMLS_DIR . "$sha1.xml") {
         copy $xml_file, XMLS_DIR . "$sha1.xml";
         $xml_repo->run(add => '.');
         $xml_repo->run(commit => '-m', "update '$title', zip - $zip");
         good_add_edge($zip, $sha1, $sha1);
      } else {
         copy $xml_file, XMLS_DIR . "$sha1.xml";
         $xml_repo->run(add => '.');
         $xml_repo->run(commit => '-m', "add '$title'" . ($DEBUG ? ", zip - $zip" : ''));
         my @log = $xml_repo->run(log => '--diff-filter=C', '-C', "-C@{[SIMILARITY_INDEX]}%", '--summary', '--format="% "', '-1');
         my ($tmp_str) = @log = grep {/^ copy/} @log;
         my ($desc) = map {m/^\s+copy (.*)\.xml => (.*)\.xml \(([0-9]+)%\)/; {old_name => $1, new_name => $2}} @log;
         my $isExist = 0;
         my $tmp_sha = defined $desc ? $desc->{old_name} : '-';
         $isExist = $desc->{new_name} eq ($tmp_sha = $reverse_renamings{$tmp_sha}) while !$isExist && exists $reverse_renamings{$tmp_sha};
         if (defined $desc && -e XMLS_DIR . "$desc->{old_name}.xml" && !$isExist) {
            $xml_repo->run(rm => "$desc->{old_name}.xml");
            $xml_repo->run(commit => '-m', "delete old version of '$title'");
            if ($desc->{new_name} ne $sha1) {
               print "error with renames DETERMINATION\n";
               exit;
            }
            good_add_edge($zip, $desc->{old_name}, $desc->{new_name});
            add_to_sha_zip($zip, $desc->{new_name});
         } else {
            add_start_v($zip, $sha1);
         }
      }
   };
   add_failed_zip($zip) if $@;
   rmtree TMP_ZIP_DIR;
}
print_failed_zips;

#-----------------------------------------------------------------
#----------------------GET ALL TASKS FROM DB----------------------
#-----------------------------------------------------------------
CATS::DB::sql_connect;
my $ary_ref = $dbh->selectall_arrayref('SELECT id, title FROM problems ORDER BY id');
my %tasks = ();
my %titles = ();
foreach (@$ary_ref) {
   my ($id, $title) = @$_;
   utf8::encode($title);
   my $sha_title = sha1_hex($title);
   $titles{$sha_title} = $title;
   if (defined $tasks{$sha_title} && @{$tasks{$sha_title}} > 0) {
      push @{$tasks{$sha_title}}, $id;
   } else {
      $tasks{$sha_title} = [$id];
   }
}

#-----------------------------------------------------------------
#-------------------FIND ERRORS WITH ZIP CHAINS-------------------
#-----------------------------------------------------------------
CATS::DB::sql_disconnect;
my %used_titles = ();
sub set_id {
   my ($desc, $amount) = @_;
   my $has_error = 0;
   $desc->{res_id} = $desc->{own_id} = undef;
   $desc->{err} = [];
   # print Dumper($desc);
   if (exists $tasks{$desc->{title}}) {
      $used_titles{$desc->{title}} = 1;
      $amount++;
      $has_error = @{$tasks{$desc->{title}}} > 1;
      push @{$desc->{err}}, 1 if $has_error; #"There is more than one id for $desc->{zip}"
      $desc->{own_id} = $tasks{$desc->{title}}->[0];
   } elsif (!exists $edges{$desc->{zip}}) {
      $has_error = 1;
      push @{$desc->{err}}, 4; #нету айди для последней задачи в цепочке
   }
   if (!exists $edges{$desc->{zip}}) {
      $desc->{res_id} = $desc->{own_id};
      $desc->{has_error} = $has_error || $amount > 1 || !$amount;
      push @{$desc->{err}}, 2 if $amount > 1; #много входов из таблицы problems в цепочку истории
      push @{$desc->{err}}, 3 if !$amount; #нету входов из таблицы задач
   } else {
      ($desc->{res_id}, $desc->{has_error}) = @{set_id($edges{$desc->{zip}}, $amount)};
   }
   return [$desc->{res_id}, $desc->{has_error}];
}

$_->{has_error} = set_id($_, 0)->[1] foreach @start_v;

foreach (@start_v) {
   next if !$_->{has_error};
   my @errors = ();
   my $lv = $_;
   my $chain = $lv->{zip};
   my $titles_chain = "'$titles{$lv->{title}}'";
   my $other_ids = $_->{own_id};
   while (exists $edges{$lv->{zip}}) {
      push @errors, "ERROR: There is more than one id for $lv->{zip}" if 1 ~~ @{$lv->{err}};
      my $res_id = defined $lv->{res_id} ? $lv->{res_id} : -1;
      $lv = $edges{$lv->{zip}};
      $other_ids .= " $lv->{own_id}" if defined $lv->{own_id} && ($lv->{own_id} != $res_id);
      $chain .= " => $lv->{zip}";
      $titles_chain .= " => '$titles{$lv->{title}}'";
   }
   foreach my $err (@{$lv->{err}}) {
      my $err_str;
      if ($err == 1) {
         $err_str = "ERROR: There is more than one id for $lv->{zip}";
      } elsif ($err == 2) {
         $err_str = "ERROR: More than one record in the database corresponds to the archives in the chain\nID'S:$other_ids";
      } elsif ($err == 3) {
         $err_str = "FATAL ERROR: There are no records in the database corresponding to the archives in the chain";
      } elsif ($err == 4) {
         $err_str = "FATAL ERROR: There is no record in the database for the last archive $lv->{zip} in the chain";
      }
      push @errors, $err_str if defined $err_str;
   }
   $, = "\n";
   print ERROR_V_DEL . "\nCHAIN: $chain\n";
   print "TITLE CHAIN: $titles_chain\n";
   print @errors;
   print "\n@{[ERROR_V_DEL]}\n";
}

foreach my $k (keys %tasks) {
   next if exists $used_titles{$k};
   print "ERROR: No corresponding archive for id $_\n" foreach @{$tasks{$k}};
}
# print Dumper(@start_v);
# print "\n\n\n";
# print Dumper %edges;
# print "\n\n\n";
# print Dumper %tasks;

# print "\nZIP CHAINS\n";
# my $amount = 0;
# foreach (@start_v) {
#    print "$_->{zip}";
#    $amount++;
#    my $zip = $_->{zip};
#    while (exists $edges{$zip}) {
#       print " => ";
#       $zip = $edges{$zip}{zip};
#       print "$zip";
#       $amount++;
#    }
#    print "\n";
# }

# print "\nAMOUNT = " . $amount;
# print "\n";

#-----------------------------------------------------------------
#------------------REPOSITORY CREATION FOR TASKS------------------
#-----------------------------------------------------------------
REPOSITORY_CREATION:
mkdir REPOS_DIR if !$needAuthorTable;
foreach my $root (@start_v) {
   next if !defined $root->{res_id};
   my $repo_path = REPOS_DIR . $root->{res_id};
   my $v = $root;
   my $prev_title;
   mkdir $repo_path;
   Git::Repository->run(init => $repo_path);
   do {
      my $zip_path = PROBLEMS_DIR . $v->{zip};
      extract_zip($zip_path);
      my ($xml_file) = glob(TMP_ZIP_DIR . '*.xml');
      my $xml;
      eval { $xml = XML::LibXML->load_xml(location => $xml_file); };
      error('corrupt xml file') if $@;
      my ($el) = $xml->getDocumentElement()->getElementsByTagName('Problem');
      my $title = $el->getAttribute('title');
      utf8::encode($title);
      $_ = $el->getAttribute('author') if defined $el->getAttribute('author');
      $_ = DEFAULT_AUTHOR if $_ ~~ undef || $_ eq '';
      utf8::encode($_);
      $_ = (split ',')[0];
      s/\(.*\)//;
      s/^\s*(.*?)\s*$/$1/;
      my $author = $_;
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
      copy $_, $repo_path foreach glob(TMP_ZIP_DIR . '*');
      my $commit_msg = !defined $prev_title ? 'Initial commit' : ($prev_title ne $v->{title} ? "Rename task to '$title'": 'Change task');
      $commit_msg .= ", zip - $v->{zip}" if $DEBUG;
      $repo->run(add => '-A');
      $repo->run(commit => '-m', $commit_msg, sprintf("--date='%s +1100'", stat($zip_path)->mtime));
      $prev_title = $v->{title};
      rmtree TMP_ZIP_DIR;
      $v = $edges{$v->{zip}};
   } while (defined $v);
}

if ($needAuthorTable) {
   open FILE, '>authors.txt' or die $!;
   foreach (sort @authors) {
      utf8::encode($_);
      print FILE "$_\n";
   }
   close FILE;
}
