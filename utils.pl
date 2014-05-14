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

my @failed_zips = ();

sub add_failed_zip {
   push @failed_zips, {zip => $_[0], msg => $error};
}

sub print_failed_zips {
   print "=======failed zips=======\n" if @failed_zips > 1;
   foreach (@failed_zips) {
      print " $_->{zip} - $_->{msg}\n";
   }
}

1;