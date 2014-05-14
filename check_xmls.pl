#!/usr/bin/perl

BEGIN { require "utils.pl"; }

opendir my $dh, REPOS_DIR or die "$0: opendir: $!";
foreach (grep {-d REPOS_DIR . "/$_" && ! /^\.{1,2}$/} readdir($dh)) {
   my @xmls = glob(REPOS_DIR . "/$_/*.xml");
   print "$_ contain " . scalar @xmls . " files\n" if @xmls > 1;
}

closedir $dh;