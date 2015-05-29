#!/usr/bin/perl

BEGIN {
   require "utils.pl";
}

use strict;
use warnings;
use Authors;
use lib CATS_DB;
use CATS::DB;
use CATS::BinaryFile;
use File::Path;
use File::Copy;
use File::stat;
use File::Touch;
use XML::LibXML;
use Digest::SHA qw(sha1_hex);
use DateTime::Format::Strptime;
use Git::Repository;
use CATS::Problem::Text;
use Archive::Zip qw( :ERROR_CODES );
use constant {
   LOG_FILE =>  'log',
   ERROR_V_DEL =>'------------------------------------------------------------------------------------------------------------------------------------------------',
   LIST_PROCESSING => 'list_proc.txt'
};
use Data::Dumper;

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
rmtree ADDITIONAL_ZIP_DIR;
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

#-----------------------------------------------------------------
#----------------------GET ALL TASKS FROM DB----------------------
#-----------------------------------------------------------------
my @additional_zips = ();
my $strp = DateTime::Format::Strptime->new(pattern => '%d.%m.%Y %R', time_zone => 'Asia/Vladivostok');
sub download_problem {
   my ($pid) = @_;
   my @ch = ('a'..'z', 'A'..'Z', '0'..'9');
   my $hash = join '', map @ch[rand @ch], 1..32;
   my ($udate, $zip_data) = eval { $dbh->selectrow_array('SELECT upload_date, zip_archive FROM problems WHERE id = ?', undef, $pid); };
   # print "Downloading problem $pid into $hash\n";
   if (!$@) {
      my $zip_name =  ADDITIONAL_ZIP_DIR . "problem_$hash.zip";
      CATS::BinaryFile::save($zip_name, $zip_data);
      File::Touch->new(mtime => $strp->parse_datetime($udate)->epoch())->touch($zip_name);
      push @additional_zips, $zip_name;
   }
}
CATS::DB::sql_connect;
my $ary_ref = $dbh->selectall_arrayref('SELECT id, title, author, hash FROM problems ORDER BY id');
$dbh->commit;
my %db_tasks = ();
my %titles = ();
mkdir ADDITIONAL_ZIP_DIR;
foreach (@$ary_ref) {
   my ($id, $title, $author, $hash) = @$_;
   $author ||= '';
   utf8::encode($title);
   utf8::encode($author);
   my $zip_name;
   $zip_name = "problem_$hash.zip" if defined $hash;
   download_problem($id) if !defined $hash || (!-f ADDITIONAL_PROBLEMS_DIR . $zip_name && !-f PROBLEMS_DIR . $zip_name);
   my $sha = sha1_hex($title . $author);
   $titles{$sha} = $title . " ($author)";
   push @{$db_tasks{$sha} //= []}, $id;
}

my %zip_files = map {$_ => stat($_)->mtime} (glob(ADDITIONAL_PROBLEMS_DIR . '*.zip'), glob(PROBLEMS_DIR . '*.zip'), @additional_zips);
my @zip_files = sort{$zip_files{$a} <=> $zip_files{$b}} keys %zip_files;
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
   push @{$sha_zip{$sha} //= []}, $zip;
   $zip_sha{$zip} = $sha;
}

sub add_start_v {
   my ($zip, $sha) = @_;
   push @start_v, {zip => $zip, sha => $sha};
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
         $edges{$leaf} = {zip => $zip, sha => $sha2};
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
foreach my $zip_path (@zip_files) {
   next if exist_failed_zip($zip_path);
   eval {
      extract_zip($zip_path);
      my ($xml_file) = glob(TMP_ZIP_DIR . '*.xml');
      my $xml;
      eval { $xml = XML::LibXML->load_xml(location => $xml_file); };
      error('corrupt xml file') if $@;
      my ($el) = $xml->getDocumentElement()->getElementsByTagName('Problem') or error('no Problem');
      my $title = $el->getAttribute('title') or error('No title');
      my $author = '';
      $author = $el->getAttribute('author') if defined $el->getAttribute('author');
      utf8::encode($title);
      utf8::encode($author);
      my $new_sha = sha1_hex($title . $author);
      $titles{$new_sha} = $title . " ($author)";
      if (-e XMLS_DIR . "$new_sha.xml") {
         copy $xml_file, XMLS_DIR . "$new_sha.xml";
         $xml_repo->run(add => '.');
         $xml_repo->run(commit => '-m', "update '$title', zip - $zip_path");
         good_add_edge($zip_path, $new_sha, $new_sha);
      } else {
         copy $xml_file, XMLS_DIR . "$new_sha.xml";
         $xml_repo->run(add => '.');
         $xml_repo->run(commit => '-m', "add '$title'" . ($DEBUG ? ", zip - $zip_path" : ''));
         my @log = $xml_repo->run(log => '--diff-filter=C', '-C', "-C@{[SIMILARITY_INDEX]}%", '--summary', '--format="% "', '-1');
         my ($tmp_str) = @log = grep {/^ copy/} @log;
         my ($renaming_desc) = map {m/^\s+copy (.*)\.xml => (.*)\.xml \(([0-9]+)%\)/; {old_sha => $1, new_sha => $2}} @log;
         my $isExist = 0;
         my $tmp_sha = defined $renaming_desc ? $renaming_desc->{old_sha} : '-';
         $isExist = $renaming_desc->{new_sha} eq ($tmp_sha = $reverse_renamings{$tmp_sha}) while !$isExist && exists $reverse_renamings{$tmp_sha};
         if (defined $renaming_desc && -e XMLS_DIR . "$renaming_desc->{old_sha}.xml" && !$isExist) {
            $xml_repo->run(rm => "$renaming_desc->{old_sha}.xml");
            $xml_repo->run(commit => '-m', "delete old version of '$title'");
            if ($renaming_desc->{new_sha} ne $new_sha) {
               print "error with renames DETERMINATION\n";
               exit;
            }
            good_add_edge($zip_path, $renaming_desc->{old_sha}, $renaming_desc->{new_sha});
            add_to_sha_zip($zip_path, $renaming_desc->{new_sha});
         } else {
            add_start_v($zip_path, $new_sha);
         }
      }
   };
   add_failed_zip($zip_path) if $@;
   rmtree TMP_ZIP_DIR;
}
print_failed_zips;

#-----------------------------------------------------------------
#-------------------FIND ERRORS WITH ZIP CHAINS-------------------
#-----------------------------------------------------------------
CATS::DB::sql_disconnect;
my %used_titles = ();
sub set_repo_id {
   my ($v) = @_;
   my $amount = 0;
   my @ids = ();
   my @vertexes = ();
   do {
      $v = $edges{$v->{zip}} if @vertexes;
      push @vertexes, $v;
      $v->{err} = [];
      $v->{res_id} = $v->{own_id} = undef;
      if (exists $db_tasks{$v->{sha}}) {
         $used_titles{$v->{sha}} = 1;
         $amount++;
         push @{$v->{err}}, 1 if @{$db_tasks{$v->{sha}}} > 1; #"There is more than one id for $v->{zip}"
         $v->{own_id} = $db_tasks{$v->{sha}}->[0];
      }
      push @ids, $v->{own_id} if defined $v->{own_id} && !($v->{own_id} ~~ @ids);
   } while (exists $edges{$v->{zip}});
   push @{$v->{err}}, 2 if @ids > 1; #много входов из таблицы problems в цепочку истории
   push @{$v->{err}}, 3 if !$amount; #нету входов из таблицы задач
   push @{$v->{err}}, 4 if !exists $db_tasks{$v->{sha}}; #нету айди для последней задачи в цепочке
   my $res_id = $v->{own_id};
   $_->{res_id} = $res_id foreach @vertexes;
   return $v->{res_id};
}

set_repo_id($_) foreach (@start_v);

my $good_amount = 0;
my $total_err_amount = 0;
my $fatal_err_amount = 0;
my %fix_ids = ();
my $fix_sql_pattern = q~UPDATE PROBLEMS SET repo_id = '%d', commit_sha = '%s' WHERE id = %d;~;
foreach my $start_vertex (@start_v) {
   my @errors = ();
   my $ch = [];
   my $last_vertex = $start_vertex;
   for (my $v = $start_vertex; $v; $v = $edges{$v->{zip}}) {
      foreach my $err (@{$v->{err}}) {
         if ($err == 1) {
            my $data = '';
            $data .= "$_ " foreach @{$db_tasks{$v->{sha}}};
            chop $data;
            push @errors, "ERROR: There is more than one id for title '$titles{$v->{sha}}' in $v->{zip}\n   ID'S: $data";
         }
      }
      $last_vertex = $v;
      push @$ch, $v;
   }
   my $other_ids = join ' => ', map {defined $_->{own_id} ? $_->{own_id} : 'undef'}  @$ch;
   if (2 ~~ @{$last_vertex->{err}}) {
      push @errors, "ERROR: More than one record in the database corresponds to the archives in the chain\n   OTHER ID'S: $other_ids";
      my @used_ids = ();
      for (my $v = $start_vertex; $v && defined $v->{res_id}; $v = $edges{$v->{zip}}) {
         if (defined $v->{own_id} && $v->{own_id} != $v->{res_id}) {
            # die "EPIC FAIL: ID $v->{own_id} ALREDY USED" if exists $fix_ids{$v->{own_id}};
            # $fix_ids{$v->{own_id}} = 1;
            push @used_ids, $v->{own_id} if !($v->{own_id} ~~ @used_ids);
         }
      }
      foreach (@used_ids) {
         die "EPIC FAIL: ID $_ ALREDY USED" if exists $fix_ids{$_};
      }
      $fix_ids{$_} = 1 foreach @used_ids;
   }
   my $isExistFatal;
   push @errors, "FATAL ERROR: There are no records in the database corresponding to the archives in the chain"
      if $isExistFatal = 3 ~~ @{$last_vertex->{err}};
   if (4 ~~ @{$last_vertex->{err}}) {
      $isExistFatal = 1;
      push @errors, "FATAL ERROR: There is no record in the database for the last archive $last_vertex->{zip} in the chain";
   }
   my $zips_chain = join " =>\n\t", map "$_->{zip}", @$ch;
   my $titles_chain = join " =>\n\t", map "$_->{sha}: $titles{$_->{sha}}", @$ch;
   $good_amount++ if !$isExistFatal;
   $total_err_amount++ if @errors > 0;
   $fatal_err_amount++ if $isExistFatal;
   $, = "\n";
   print ERROR_V_DEL . "\nZIPS CHAIN:\n\t$zips_chain\n";
   print "TITLE CHAIN:\n\t$titles_chain\n";
   print @errors if @errors > 0;
   print "\n";
}

print "\n" . ERROR_V_DEL . "\n";
my $hanging_rec = 0;
foreach my $k (keys %db_tasks) {
   next if exists $used_titles{$k};
   $hanging_rec++;
   printf "ERROR: No corresponding archive for ids %s (%s)\n", join(',', @{$db_tasks{$k}}), $titles{$k};
}

print "\n=================================================================================================\n";
print "STORIES CREATED: $good_amount\n";
print "FATAL ERRORS AMOUNT: $fatal_err_amount\n";
print "TOTAL CHAIN ERRORS AMOUNT: $total_err_amount\n";
print "HANGING RECORDS AMOUNT: $hanging_rec\n";
#-----------------------------------------------------------------
#------------------REPOSITORY CREATION FOR TASKS------------------
#-----------------------------------------------------------------
REPOSITORY_CREATION:
my %fix_sqls = ();
mkdir REPOS_DIR if !$needAuthorTable;
foreach my $root (@start_v) {
   my $repo_path = REPOS_DIR . (defined $root->{res_id} ? $root->{res_id} : BAD_PROBLEMS_DIR . $root->{sha}) . '/';
   my $v = $root;
   my $prev_title;
   mkdir $repo_path;
   Git::Repository->run(init => $repo_path);
   do {
      extract_zip($v->{zip});
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
      my ($git_author, $git_author_email) = get_git_author_info($author);
      my $repo = Git::Repository->new(work_tree => $repo_path, {
         env => {
            GIT_AUTHOR_NAME  => $git_author,
            GIT_AUTHOR_EMAIL => $git_author_email
         }
      });
      $repo->run(rm => '*', '--ignore-unmatch');
      copy $_, $repo_path foreach glob(TMP_ZIP_DIR . '*');
      my $mtime = stat($v->{zip})->mtime;
      File::Touch->new(mtime => $mtime)->touch((glob($repo_path . '*'), $repo_path));
      my $commit_msg = !defined $prev_title ? 'Initial commit' : ($prev_title ne $v->{sha} ? "Rename task to '$title'": 'Change task');
      $commit_msg .= ", zip - $v->{zip}" if $DEBUG;
      $repo->run(add => '-A');
      $repo->run(commit => '-m', $commit_msg, sprintf("--date='%s +1100'", $mtime));
      $repo->run('gc');
      if (defined $v->{own_id} && exists $fix_ids{$v->{own_id}} && !exists $fix_sqls{$v->{own_id}}) {
         my $sha = $repo->run('rev-parse' => 'HEAD');
         $fix_sqls{$v->{own_id}} = sprintf $fix_sql_pattern, $v->{res_id}, $sha, $v->{own_id};
      }
      $prev_title = $v->{sha};
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

if (%fix_sqls) {
   print "fix_inserts.sql CREATED!!\n";
   open FILE, '>fix_inserts.sql' or die $!;
   print FILE "$_\n" foreach values %fix_sqls;
   close FILE;
}


