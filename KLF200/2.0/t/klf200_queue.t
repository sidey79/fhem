#!/usr/bin/perl
# Tests for the command queue timeout in 83_KLF200.pm.
#   cd KLF200/2.0 && perl t/klf200_queue.t
package main;
use strict;
use warnings;
use Test::More tests => 6;
use FindBin;
use lib "$FindBin::Bin/stub";

require "$FindBin::Bin/fhem_stub.pl";
our (%READINGS, @TIMERS, @WRITTEN, @LOG, @READ_CHUNKS, %defs);

my $module = "$FindBin::Bin/../FHEM/83_KLF200.pm";
do $module;
die "cannot load $module: $@" if($@);

# ---------------------------------------------------------------- helpers
sub new_hash {
  my %h = (NAME => "KLF", TYPE => "KLF200", Host => "1.2.3.4", TCPDev => 1,
           ".queue" => [], PARTIAL => "");
  my $hash = \%h;
  $main::defs{KLF} = $hash;
  %main::READINGS = (KLF => { state => "Logged in" });
  @main::TIMERS = ();
  @main::WRITTEN = ();
  @main::LOG = ();
  @main::READ_CHUNKS = ();
  KLF200_InitTexts($hash);
  return $hash;
}

# build a complete SLIP frame the way the box would send it
sub build_frame {
  my ($payload) = @_;
  my $body = "\x00" . pack("C", length($payload) + 1) . $payload;
  my $crc = 0;
  $crc ^= $_ for unpack('C*', $body);
  $body .= pack("C", $crc);
  $body =~ s/\xDB/\xDB\xDD/g;
  $body =~ s/\xC0/\xDB\xDC/g;
  return "\xC0" . $body . "\xC0";
}

my @dispatched;
{
  no warnings qw(redefine prototype once);
  no strict 'refs';
  *main::KLF200_DispatchFrame = sub { my ($h,$b)=@_; push @dispatched, unpack("H*",$b); return };
}

sub read_chunks {
  my ($hash, @chunks) = @_;
  @dispatched = ();
  for my $c (@chunks) {
    @main::READ_CHUNKS = ($c);
    KLF200_Read($hash);
  }
  return @dispatched;
}

my $hash;

# ---------------------------------------------------------------- 13. queue timeout: query is retried once
{
  no warnings qw(redefine prototype once);
  no strict 'refs';
  *main::KLF200_DispatchFrame = sub { return };
}
$hash = new_hash();
KLF200_Write($hash, "\x02\x02");                       # GW_GET_ALL_NODES_INFORMATION_REQ
is(scalar(@main::WRITTEN), 1, "queued request is sent immediately");
ok(HasTimer($hash,"KLF200_QueueTimeout"), "a queue timeout is armed");
FireTimer($hash,"KLF200_QueueTimeout");
is(scalar(@main::WRITTEN), 2, "query is repeated once after a timeout");
FireTimer($hash,"KLF200_QueueTimeout");
is(scalar(@{$hash->{".queue"}}), 0, "query is dropped after the second timeout");

# ---------------------------------------------------------------- 14. queue timeout: movement is never repeated
$hash = new_hash();
KLF200_Write($hash, "\x03\x00" . pack("n",1));         # GW_COMMAND_SEND_REQ
FireTimer($hash,"KLF200_QueueTimeout");
is(scalar(@main::WRITTEN), 1, "movement command is not repeated");
is(scalar(@{$hash->{".queue"}}), 0, "movement command is dropped and the queue continues");
