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
   CATS_DB          => '../../web/cats-main/cgi-bin',
   TMP_ZIP          => 'tmp_zip.zip',
   XMLS_DIR         => 'task_xmls',
   REPOS_DIR        => 'tasks_rep',
   TMP_ZIP_DIR      => 'dir',
   PROBLEMS_DIR     => 'prs',
   SIMILARITY_INDEX => 80
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