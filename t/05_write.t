use strict;
use warnings;
use utf8;
use Test::More tests => 6;
use Win32::Unicode;
use File::Temp qw/tempdir tempfile/;

my $str = 'ぁぃぅぇぉ';
{
	# print
	my ($fh, $filename) = tempfile("tempXXXX", DIR => tempdir(CLEANUP => 1)) or die "$!";
	binmode $fh, ":utf8";
	ok printW $fh, $str;
	close $fh;
	
	open $fh, "<:utf8", $filename or die "$!";
	my $buff = do { local $/; <$fh> };
	is $buff, $str;
	close $fh;
}

{
	# printf
	my ($fh, $filename) = tempfile("tempXXXX", DIR => tempdir(CLEANUP => 1)) or die "$!";
	binmode $fh, ":utf8";
	ok printfW $fh, $str;
	close $fh;
	
	open $fh, "<:utf8", $filename or die "$!";
	my $buff = do { local $/; <$fh> };
	is $buff, $str;
	close $fh;
}

{
	# say
	my ($fh, $filename) = tempfile("tempXXXX", DIR => tempdir(CLEANUP => 1)) or die "$!";
	binmode $fh, ":utf8";
	ok sayW $fh, $str;
	close $fh;
	
	open $fh, "<:utf8", $filename or die "$!";
	my $buff = do { local $/; <$fh> };
	is $buff, "$str\n";
	close $fh;
}