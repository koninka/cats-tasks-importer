#!/usr/bin/perl

#authors consts
use constant {
   KLENINS_EMAIL   => 'klenin@gmail.com',
   DEFAULT_EMAIL   => 'unknown@example.com',
   DEFAULT_AUTHOR  => 'Unknown Author',
   EXTERNAL_AUTHOR => 'external'
};

#directories consts
use constant {
   CATS_DB                 => '/home/mark/development/web/cats-main/cgi-bin',
   TMP_ZIP                 => 'tmp_zip.zip',
   XMLS_DIR                => 'tasks_xmls/',
   REPOS_DIR               => '/home/mark/development/web/cats-main/cgi-bin/repos',
   TMP_ZIP_DIR             => 'dir/',
   PROBLEMS_DIR            => 'prs/',
   SIMILARITY_INDEX        => 80,
   BAD_PROBLEMS_DIR        => 'bad/',
   ADDITIONAL_ZIP_DIR      => 'db_prs/',
   ADDITIONAL_PROBLEMS_DIR => 'pr/',
   MISSED_FOLDER_FNAME     => 'missed_folders.txt',
};

my $error;
sub error {
   $error = $_[0];
   die;
}

sub set_error {
   $error = $_[0];
}

sub get_error {
   return $error;
}

my %failed_zips = ();

sub add_failed_zip {
   $failed_zips{$_[0]} = $error;
}

sub exist_failed_zip {
   return exists $failed_zips{$_[0]};
}

sub extract_zip {
   my $zip = Archive::Zip->new();
   $zip->read($_[0]) == AZ_OK or error("can't read");
   my @xml_members = $zip->membersMatching('.*\.xml$');
   error('*.xml not found') if !@xml_members;
   error('found several *.xml in archive') if @xml_members > 1;
   $zip->extractTree('', TMP_ZIP_DIR) == AZ_OK or error("can't extract");
}

sub print_failed_zips {
   print "=======failed zips=======\n" if @failed_zips > 1;
   foreach (keys %failed_zips) {
      utf8::encode($failed_zips{$_});
      print " $_ - $failed_zips{$_}\n";
   }
}

sub get_failed_amount {
   return scalar keys %failed_zips;
}

1;