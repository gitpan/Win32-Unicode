package Win32::Unicode::Dir;

use strict;
use warnings;
use 5.008003;
use Win32 ();
use Win32::API ();
use Carp ();
use File::Basename qw/basename dirname/;
use Exporter 'import';

use Win32::Unicode::Util;
use Win32::Unicode::Error;
use Win32::Unicode::Constant;
use Win32::Unicode::Define;
use Win32::Unicode::File;
use Win32::Unicode::Console;

# export subs
our @EXPORT    = qw/file_type file_size mkdirW rmdirW getcwdW chdirW findW finddepthW mkpathW rmtreeW mvtreeW cptreeW dir_size file_list dir_list/;
our @EXPORT_OK = qw//;
our %EXPORT_TAGS = ('all' => [@EXPORT, @EXPORT_OK]);

our $VERSION = '0.19';

# global vars
our $cwd;
our $name;
our $skip_pattern = qr/\A(?:(?:\.{1,2})|(?:System Volume Information))\z/;

sub new {
    my $class = shift;
    bless {}, $class;
}

# like CORE::opendir
sub open {
    my $self = shift;
    my $dir = shift;
    _croakW('Usage $obj->open(dirname)') unless defined $dir;
    
    $self->{FileInfo} = Win32::API::Struct->new('WIN32_FIND_DATAW');
    
    $dir = cygpathw($dir) or return if CYGWIN;
    
    $self->{dir} = catfile $dir, '*';
    $dir = utf8_to_utf16($self->{dir}) . NULL;
    
    $self->{handle} = FindFirstFile->Call($dir, $self->{FileInfo});
    return Win32::Unicode::Error::_set_errno if $self->{handle} == INVALID_HANDLE_VALUE;
    
    $self->{first} = $self->_cFileName;
    
    return $self;
}

# like CORE::closedir
sub close {
    my $self = shift;
    _croakW("Can't open directory handle") unless $self->{handle};
    return Win32::Unicode::Error::_set_errno unless FindClose->Call($self->{handle});
    delete @$self{qw[dir handle first FileInfo]};
    return 1;
}

# like CORE::readdir
sub fetch {
    my $self = shift;
    _croakW("Can't open directory handle") unless $self->{handle};
    
    # if defined first file
    my $first;
    if ($self->{first}) {
        $first = $self->{first};
        delete $self->{first};
    }
    
    # array or scalar
    if (wantarray) {
        my @files;
        
        push @files, $first if $first;
        while (FindNextFile->Call($self->{handle} ,$self->{FileInfo})) {
            push @files, $self->_cFileName;
        }
        
        return @files;
    }
    else {
        return $first if $first;
        return Win32::Unicode::Error::_set_errno unless FindNextFile->Call($self->{handle} ,$self->{FileInfo});
        return $self->_cFileName;
    }
}

*read = *readdir = \&fetch;

sub _cFileName {
    my $self = shift;
    my $cFileName = do {
        use bytes;
        unpack "x44A520", $self->{FileInfo}->{buffer};
    };
    delete $self->{FileInfo}->{cFileName};
    return utf16_to_utf8($cFileName . NULL);
};

# like use Cwd qw/getcwd/;
sub getcwdW {
    my $buff = BUFF;
    my $length = GetCurrentDirectory->Call(MAX_PATH + 1, $buff);
    return utf16_to_utf8(substr $buff, 0, $length * 2);
}

# like CORE::chdir
sub chdirW {
    my $set_dir = shift;
    my $retry = shift || 0;
    _croakW('Usage: chdirW(dirname)') unless defined $set_dir;
    $set_dir = cygpathw($set_dir) or return if CYGWIN;
    $set_dir = utf8_to_utf16(catfile $set_dir) . NULL;
    return Win32::Unicode::Error::_set_errno unless SetCurrentDirectory->Call($set_dir);
    return chdirW(utf16_to_utf8($set_dir), ++$retry) if CYGWIN && !$retry; # bug ?
    return 1;
}

# like CORE::mkdir
sub mkdirW {
    my $dir = defined $_[0] ? $_[0] : $_;
    $dir = cygpathw($dir) or return if CYGWIN;
    return Win32::CreateDirectory(catfile $dir) ? 1 : Win32::Unicode::Error::_set_errno;
}

# like CORE::rmdir
sub rmdirW {
    my $dir = defined $_[0] ? $_[0] : $_;
    $dir = cygpathw($dir) or return if CYGWIN;
    $dir = utf8_to_utf16(catfile $dir) . NULL;
    return RemoveDirectory->Call($dir) ? 1 : Win32::Unicode::Error::_set_errno;
}

# like File::Path::rmtree
sub rmtreeW {
    my $dir = shift;
    my $stop = shift;
    _croakW('Usage: rmtreeW(dirname)') unless defined $dir;
    $dir = catfile $dir;
    return unless file_type(d => $dir);
    my $code = sub {
        my $file = $_;
        if (file_type(f => $file)) {
            if (not unlinkW $file) {
                return if $stop;
            }
        }
        
        elsif (file_type(d => $file)) {
            if (not rmdirW $file) {
                return if $stop;
            }
        }
    };
    
    finddepthW($code, $dir);
    
    return unless rmdirW($dir);
    return 1;
}

# like File::Path::mkpath
sub mkpathW {
    my $dir = shift;
    _croakW('Usage: mkpathW(dirname)') unless defined $dir;
    $dir = catfile $dir;
    
    my $mkpath = '.';
    for (splitdir $dir) {
        $mkpath = catfile $mkpath, $_;
        next if file_type d => $mkpath;
        return unless mkdirW $mkpath;
    }
    return 1;
}

# like File::Copy::copy
sub cptreeW {
    _croakW('Usage: cptreeW(from, to [, over])') unless defined $_[0] and defined $_[1];
    _cptree($_[0], $_[1], $_[2], 0);
}

sub mvtreeW {
    _croakW('Usage: mvtreeW(from, to [, over])') unless defined $_[0] and defined $_[1];
    _cptree($_[0], $_[1], $_[2], 1);
}

my $is_drive = qr/^[a-zA-Z]:/;
my $in_dir   = qr#[\\/]$#;

sub _cptree {
    my $from = shift;
    my $to = shift;
    my $over = shift || 0;
    my $bymove = shift || 0;
    
    _croakW("$from: no such directory") unless file_type d => $from;
    
    $from = cygpathw($from) or return if CYGWIN;
    $from = catfile $from;
    $to = cygpathw($to) or return if CYGWIN;
    
    if ($to =~ $is_drive) {
        $to = catfile $to, basename($from) if $to =~ $in_dir;
        $to = catfile $to;
    }
    else {
        $to = catfile getcwdW(), $to, basename($from) if $to =~ $in_dir;
        $to = catfile getcwdW(), $to;
    }
    
    unless (file_type d => $to) {
        mkpathW $to or _croakW("$to " . errorW);
    }
    
    my $replace_from = quotemeta $from;
    my $code = sub {
        my $from_file = $_;
        my $from_full_path = $Win32::Unicode::Dir::name;
        
        (my $to_file = $from_full_path) =~ s/$replace_from//;
        $to_file = catfile $to, $to_file;
        
        if (file_type d => $from_file) {
            rmdirW $from_file if $bymove;
            return;
        }
        
        my $to_dir = dirname $to_file;
        mkpathW $to_dir unless file_type d => $to_dir;
        
        if (file_type f => $from_file) {
            if ($over || not file_type f => $to_file) {
                ($bymove
                    ? moveW($from_file, $to_file, $over)
                    : copyW($from_file, $to_file, $over)
                ) or _croakW("$from_full_path to $to_file can't file copy ", errorW);
            }
        }
    };
    
    finddepthW($code, $from);
    if ($bymove) {
        return unless rmdirW $from;
    }
    return 1;
}

# like File::Find::find
sub findW {
    _croakW('Usage: findW(code_ref, dir)') unless @_ >= 2;
    my $code = shift;
    _find_wrap($code, 0, @_);
    return 1;
}

# like File::Find::finddepth
sub finddepthW {
    _croakW('Usage: finddepthW(code_ref, dir)') unless @_ >= 2;
    my $code = shift;
    _find_wrap($code, 1, @_);
    return 1;
}

sub _find_wrap {
    my $code = shift;
    my $bydepth = shift;
    for my $arg (@_) {
        my $dir = $arg;
        $dir = cygpathw($dir) or return if CYGWIN;
        $dir = catfile $dir;
       _croakW("$dir: no such directory") unless file_type(d => $dir);
        
        my $current = getcwdW;
        _find($code, $dir, $bydepth);
        chdirW($current);
        $name = $cwd = undef;
    }
}

sub _find {
    my $code = shift;
    my $dir = shift;
    my $bydepth = shift;
    
    chdirW $dir or _croakW("$dir ", errorW);
    
    $cwd = $cwd ? catfile($cwd, $dir) : $dir;
    
    my $wdir = Win32::Unicode::Dir->new;
    $wdir->open('.') or _croakW("can't open directory ", errorW);
    
    for my $cur ($wdir->fetch) {
        next if $cur =~ $skip_pattern;
        
        unless ($bydepth) {
            $::_ = $cur;
            $name = catfile $cwd, $cur;
            $code->({
                file => $::_,
                path => $name,
                cwd  => $cwd,
            });
        }
        
        if (file_type 'd', $cur) {
            _find($code, $cur, $bydepth);
            
            chdirW '..';
            $cwd = catfile $cwd, '..';
        }
        
        if ($bydepth) {
            $::_ = $cur;
            $name = catfile $cwd, $cur;
            $code->({
                file => $::_,
                path => $name,
                cwd  => $cwd,
            });
        }
    }
    
    $wdir->close or _croakW("can't close directory ", errorW);
}

# get dir size
sub dir_size {
    my $dir = shift;
    _croakW('Usage: dir_size(dirname)') unless defined $dir;
    
    $dir = catfile $dir;
    
    my $size = 0;
    finddepthW(sub {
        my $file = $_;
        return if file_type d => $file;
        $size += file_size $file;
    }, $dir);
    
    return $size;
}

sub file_list {
    my $dir = shift;
    _croakW('Usage: file_list(dirname)') unless defined $dir;
    
    my $wdir = __PACKAGE__->new->open($dir) or return;
    my @files = grep { !/^\.{1,2}$/ && file_type f => $_ } $wdir->fetch;
    $wdir->close;
    
    return @files;
}

sub dir_list {
    my $dir = shift;
    _croakW('Usage: dir_list(dirname)') unless defined $dir;
    
    my $wdir = __PACKAGE__->new->open($dir) or return;
    my @dirs = grep { !/^\.{1,2}$/ && file_type d => $_ } $wdir->fetch;
    $wdir->close;
    
    return @dirs;
}

# return error message
sub error {
    return errorW;
}

sub _croakW {
    Win32::Unicode::Console::_row_warn(@_);
    die Carp::shortmess();
}

sub DESTROY {
    my $self = shift;
    $self->close if defined $self->{handle};
}

1;
__END__
=head1 NAME

Win32::Unicode::Dir.pm - Unicode string directory utility.

=head1 SYNOPSIS

  use Win32::Unicode::Console;
  use Win32::Unicode::Dir;
  
  my $dir = "I \x{2665} Perl";
  
  my $wdir = Win32::Unicode::Dir->new;
  $wdir->open($dir) || die $wdir->error;
  for ($wdir->fetch) {
      next if /^\.{1,2}$/;
      
      my $full_path = "$dir/$_";
      if (file_type('f', $full_path)) {
          # $_ is file
      }
      
      elsif (file_type('d', $full_path))
          # $_ is directory
      }
  }
  $wdir->close || dieW $wdir->error;
  
  my $cwd = getcwdW();
  chdirW($change_dir_name);
  
  mkdirW $dir;
  rmdirW $dir;

=head1 DESCRIPTION

Win32::Unicode::Dir is Unicode string directory utility.

=head1 METHODS

=over

=item B<new>

  my $wdir = Win32::Unicode::Dir->new;

=item B<open($dir)>

Like opendir.

  $wdir->open($dir) or dieW $wdir->error;

=item B<fetch()>

Like readdir.

  while (my $file = $wdir->fetch) {
     # hogehoge
  }
  
or

  for my $file ($wdir->fetch) {
     $ hogehoge
  }
  
C<read> and C<readdir> is alias of fetch.

=item B<close()>

Like closedir.

  $wdir->close or dieW $wdir->error

=item B<error()>

get error message.

=back

=head1 FUNCTIONS

=over

=item B<getcwdW>

Like Cwd::getcwd.

  my $cwd = getcwdW;

=item B<chdirW($dir)>

Like chdir.

  chdirW($dir) or dieW errroW;

=item B<mkdirW($new_dir)>

Like mkdir.

  mkdirW($new_dir) or dieW errorW;

=item B<rmdirW($del_dir)>

Like rmdir.

  rmdirW($del_dir) or dieW errorW;

=item B<rmtreeW($del_dir)>

Like File::Path::rmtree.

  rmtreeW($del_dir) or dieW errorW;

=item B<mkpathW($make_long_dir_name)>

Like File::Path::mkpath.

  mkpathW($make_long_dir_name) or dieW errorW

=item B<cptreeW($from, $to [, $over])>

copy directory tree.

  cptreeW $from, $to or dieW errorW;

=item B<mvtreeW($from, $to [, $over]))>

move directory tree.

  mvtreeW $from, $to or dieW errorW;

=item B<findW($code, $dir)>

like File::Find::find.

  findW(sub {
      my $file = $_;
      my $full_path = $Win32::Unicode::Dir::name;
      my $cwd = $Win32::Unicode::Dir::cwd;
  }, $dir) or dieW errorW;

or
  findW(sub {
      my $arg = shift;
      printf "%s : %s : %s", $arg->{file}, $arg->{path}, $arg->{cwd};
  }, $dir) or dieW errorW;

=item B<finddepthW($code, $dir)>

like File::Find::finddepth.

=item B<dir_size($dir)>

get directory size.
this function are slow.

  my $dir_size = dir_size($dir) or dieW errorW

=item B<file_list($dir)>

get files from $dir

  my @files = file_list $dir;

=item B<dir_list($dir)>

get directorys from $dir

  my @dirs = dir_list $dir;

=back

=head1 AUTHOR

Yuji Shimada E<lt>xaicron@cpan.orgE<gt>

=head1 SEE ALSO

L<Win32>
L<Win32::API>
L<Win32API::File>
L<Win32::Unicode>
L<Win32::Unicode::File>
L<Win32::Unicode::Error>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
