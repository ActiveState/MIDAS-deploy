#!/usr/bin/perl -w

package  Setup;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
    create_internet_shortcuts
    create_shortcuts
    create_file_assoc
    set_system_user_env
    install_apache
);

use lib q(.);
use Archive::Zip;
use File::Spec::Functions qw(catfile);
use File::Basename qw(basename);
use Config;
use Cwd qw(cwd);
use JSON;
use List::MoreUtils qw ( apply uniq );
use Path::Tiny;

use Win32;
use Win32::API;
use Win32::Shortcut;
use Win32::TieRegistry;

our $VERSION           = '0.02';
my $SHCNE_ASSOCCHANGED = 0x8_000_000;
my $SCNF_FLUSH         = 0x1000;

my $ORGANIZATION = 'ActiveState';
my $PROJECT      = 'Perl-5.32';
my $NAMESPACE    = "$ORGANIZATION/$PROJECT";
my $PLATFORM_URL = "https://platform.activestate.com/$NAMESPACE";
my $STATE_ICO    = 'state.ico';
my $WEB_ICO      = 'web.ico';

# Import Win32 function: `void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2)`

my $SHChangeNotify = Win32::API::More->new( 'shell32', 'SHChangeNotify', 'iiPP', 'V' );
if ( not defined $SHChangeNotify ) {
    die "Can't import SHChangeNotify: ${^E}\n";
}

sub update_win32_shell {
    $SHChangeNotify->Call( $SHCNE_ASSOCCHANGED, $SCNF_FLUSH, 0, 0 );
    return;
}

sub desktop_dir_path {
    return Win32::GetFolderPath(Win32::CSIDL_DESKTOPDIRECTORY());
}

sub start_menu_path {
    return Win32::GetFolderPath(Win32::CSIDL_STARTMENU());
}

sub make_path {
    my $base = shift;

    unless (-d $base) {
        my $success = path($base)->mkpath;
        die "Couldn't create path '$base': $!" unless $success == 1;
    }
}

sub create_internet_shortcut {
    my $target  = shift;
    my $lnkPath = shift;
    my $iconPath = shift;

    if ( -e $lnkPath ) {
        unlink $lnkPath or die $!;
    }

    my $str = <<'END';
[InternetShortcut]
URL=${target}
IconFile=${iconPath}
IconIndex=0
END

    open(FH, '>', $lnkPath) or die "Couldn't create internet shortcut '$target': $!";
    print FH $str or die $!;
    close(FH) or die $!;

    return;
}

sub create_shortcut {
    my $target   = shift;
    my $args     = shift;
    my $icon     = shift;
    my $lnkPath  = shift;
    my $location = shift;

    if ( -e $lnkPath ) {
        unlink $lnkPath or die $!;
    }

    #print "Creating application shortcut: $lnkPath -> $target\n";
    my $LINK = Win32::Shortcut->new();
    $LINK->{'Path'}             = $target;
    $LINK->{'Arguments'}        = $args;
    $LINK->{'IconLocation'}     = $icon;
    $LINK->{'IconNumber'}       = 0;
    $LINK->{'WorkingDirectory'} = $location;
    $LINK->Save($lnkPath);
    $LINK->Close();

    return;
}

sub create_internet_shortcuts {
    my $target  = $PLATFORM_URL;
    my $lnkName = "$NAMESPACE Web.url";
    $lnkName =~ s{/}{ };
    my $icon = catfile(cwd, $WEB_ICO);

    my $start_menu_base = catfile(start_menu_path(), $ORGANIZATION);
    make_path($start_menu_base);
    my $startLnkPath = catfile($start_menu_base, $lnkName);
    create_internet_shortcut($target, $startLnkPath, $icon);

    my $dsktpLnkPath = catfile(desktop_dir_path(), $lnkName);
    create_internet_shortcut($target, $dsktpLnkPath, $icon);

    return;
}

sub create_shortcuts {
    my $target  = '%windir%\\system32\\cmd.exe';
    my $args     = '/k state activate';
    my $icon = catfile(cwd, $STATE_ICO);
    my $lnkName = "$NAMESPACE CLI.lnk";
    $lnkName =~ s{/}{ };

    my $start_menu_base = catfile(start_menu_path(), $ORGANIZATION);
    make_path($start_menu_base);
    my $startLnkPath = catfile($start_menu_base, $lnkName);
    create_shortcut($target, $args, $icon, $startLnkPath, cwd);

    my $dsktpLnkPath = catfile(desktop_dir_path(), $lnkName);
    create_shortcut($target, $args, $icon, $dsktpLnkPath, cwd);

    return;
}

sub create_file_assoc {
    my $cmd       = $Config{perlpath};
    my $assocsRef = ['.pl', '.perl'];

    my $cmd_name = basename($cmd);
    my $prog_id  = "$ORGANIZATION.${cmd_name}";

    # file type description
    $Registry->{"CUser\\Software\\Classes\\${prog_id}\\"} = {
        '\\' => "$cmd_name document",
        'shell\\' => {
            'open\\' => {
                'command\\' => {
                    '\\' => "$cmd %1 %*"
                }
            }
        }
    };

    foreach (@$assocsRef) {
        #print "Creating file association: $_: $prog_id\n";
        $Registry->{"CUser\\Software\\Classes\\$_\\"} = {q{} => $prog_id};
        # for Apache
        $Registry->{"HKEY_CLASSES_ROOT\\$_\\"} = {
            'Shell\\' => {
                'ExecCGI\\' => {
                    'Command\\' => {
                         '\\' => $Config{perlpath} . ' -wT'
                    }
                }
            }
        };
    }

    update_win32_shell();

    return;
}

sub find_runtime_json {
    my $perl = path($Config{perlpath});

    die q{Can't find perl} unless $perl->exists;

    my $runtime_dir = $perl->parent(2)->child('_runtime_store');
    die q{Can't find runtime_dir} unless $runtime_dir->exists;

    my $runtime_json = $runtime_dir->child('runtime.json');
    die q{Can't find runtime.json} unless $runtime_json->exists();

    return $runtime_json;
}

sub get_runtime_env {
    my $json_text = find_runtime_json()->slurp_utf8;
    my $runtime   = decode_json ( $json_text );

    my %rt_env;
    for my $env_var ( @{ $runtime->{env} } ) {
        my $var  = $env_var->{env_name};
        my @vals = @{ $env_var->{values} };
        my $sep  = $env_var->{separator};
        if ( $env_var->{inherit} ) {
            my $sys_var = get_system_user_var( $var );
            my @base = $sys_var ? split $sep, $sys_var : ();
            if ( $env_var->{join} eq 'prepend' ) {
                unshift @vals, @base;
            } else {
                push @vals, @base;
            }
        }
        @vals = uniq( apply { s{/}{\\}g } @vals );
        $rt_env{$var} = join $sep, @vals;
    }
    return \%rt_env;
}

sub get_system_user_var {
    my $var = shift;

    my $rootKey = $Registry->{'HKEY_USERS\\.DEFAULT\\Environment\\'};
    return $rootKey->{$var};
}

sub set_system_user_env {
    my $new_env = get_runtime_env();

    my $rootKey = $Registry->{'HKEY_USERS\\.DEFAULT\\Environment\\'};
    for my $key ( keys %{ $new_env } ) {
        $rootKey->{$key} = $new_env->{$key}
    }

    update_win32_shell();
}

sub find_apache_zip {
    my @apache_zips = path('.')->children( qr/^(httpd|apache).*zip$/ );
    return $apache_zips[0]->stringify if @apache_zips;
    @apache_zips = path('~/Downloads')->children( qr/^(httpd|apache).*zip$/ );
    return $apache_zips[0]->stringify if @apache_zips;
    return q{};
}

sub install_apache {
    my $apache_zip = find_apache_zip();

    my $prompt = 'Location of apache zip archive: ';
    $prompt .= "($apache_zip) " if $apache_zip;
    my $response = q{};
    my $done = 0;
    until ( $done ) {
        print($prompt) or die $!;
        $response = <STDIN>;
        chomp $response;
        if ( $response ) {
            if ( -e $response ) {
                $done = 1;
            }
            else {
                print "$response does not exist\n" or die $!;
            }
        }
        else {
            $done = 1;
        }
    }
    $apache_zip = $response if $response;

    my $zip = Archive::Zip->new( $apache_zip );

    $zip->extractTree('Apache24', '/Apache24', 'C:');

    configure_apache();
    start_apache();
}

sub configure_apache {
    my $conf = path('C:\\Apache24\\conf\\httpd.conf');
    die q{Can't find httpd.conf} unless $conf->exists;

    $conf->edit_lines_utf8(
        sub {
            s{Options Indexes FollowSymLinks}{Options Indexes FollowSymLinks ExecCGI};
            s{#AddHandler cgi-script .cgi}{AddHandler cgi-script .cgi\n    AddHandler cgi-script .pl};
        }
    );
    $conf->append_utf8('ScriptInterpreterSource Registry');
}

sub start_apache {
    system('C:\\Apache24\\bin\\httpd.exe', '-k', 'install');
    system('net', 'start', 'Apache2.4');
}


1;
