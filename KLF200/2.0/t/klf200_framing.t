#!/usr/bin/perl
# Tests for the SLIP framing and command queue changes in 83_KLF200.pm.
#   cd KLF200/2.0 && perl t/klf200_framing.t
package main;
use strict;
use warnings;
use Test::More tests => 17;
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

# ---------------------------------------------------------------- 1. roundtrip
my $hash = new_hash();
my $wrapped = KLF200_WrapBytes($hash, "\x00\x0C");
is(unpack("H*", $wrapped), unpack("H*", build_frame("\x00\x0C")),
   "WrapBytes produces the same frame as the reference builder");
is(unpack("H*", KLF200_UnwrapBytes($hash, $wrapped)), "000c",
   "UnwrapBytes returns the command of its own wrapped frame");

# ---------------------------------------------------------------- 2. one frame per read
$hash = new_hash();
my @got = read_chunks($hash, build_frame("\x03\x04\x01\x02"));
is_deeply(\@got, ["03040102"], "single frame in a single read");
is($hash->{PARTIAL}, "", "buffer is empty afterwards");

# ---------------------------------------------------------------- 3. two frames in one read (the core bug)
$hash = new_hash();
@got = read_chunks($hash, build_frame("\x03\x01\x00\x07\x00") . build_frame("\x03\x04\x00\x07"));
is_deeply(\@got, ["0301000700", "03040007"],
   "two frames in one read are both dispatched");

# ---------------------------------------------------------------- 4. three frames, one read
$hash = new_hash();
@got = read_chunks($hash, join("", map { build_frame("\x02\x04".pack("C",$_)) } (1,2,3)));
is(scalar(@got), 3, "three frames in one read are all dispatched");

# ---------------------------------------------------------------- 5. frame split across reads
$hash = new_hash();
my $f = build_frame("\x03\x04\x00\x2A");
@got = read_chunks($hash, substr($f,0,3), substr($f,3));
is_deeply(\@got, ["0304002a"], "frame split over two reads is reassembled");

# ---------------------------------------------------------------- 6. split in the middle of an escape
$hash = new_hash();
$f = build_frame("\x02\x04\xC0\xDB\x11");
@got = read_chunks($hash, substr($f,0,5), substr($f,5,2), substr($f,7));
is_deeply(\@got, ["0204c0db11"], "escaped bytes survive a split read");

# ---------------------------------------------------------------- 7. escaping roundtrip
$hash = new_hash();
@got = read_chunks($hash, build_frame("\x04\x0E\xC0\xC0\xDB\xDB"));
is_deeply(\@got, ["040ec0c0dbdb"], "SLIP escaping is undone correctly");

# ---------------------------------------------------------------- 8. trailing partial frame is kept
$hash = new_hash();
@got = read_chunks($hash, build_frame("\x03\x04\x00\x01") . substr(build_frame("\x03\x04\x00\x02"),0,4));
is_deeply(\@got, ["03040001"], "complete frame dispatched, partial one held back");
ok(length($hash->{PARTIAL}) == 4, "remainder stays in the buffer");
@got = read_chunks($hash, substr(build_frame("\x03\x04\x00\x02"),4));
is_deeply(\@got, ["03040002"], "held back frame completes with the next read");

# ---------------------------------------------------------------- 9. broken checksum
$hash = new_hash();
$f = build_frame("\x03\x04\x00\x03");
substr($f, length($f)-2, 1) = chr((ord(substr($f,length($f)-2,1)) + 1) % 256);
@got = read_chunks($hash, $f);
is_deeply(\@got, [], "frame with a wrong checksum is discarded");
is(ReadingsVal("KLF","frameErrors",0), 1, "frameErrors counted the discarded frame");

# ---------------------------------------------------------------- 10. wrong length
$hash = new_hash();
$f = build_frame("\x03\x04\x00\x04");
my $body = substr($f,1,length($f)-2);
substr($body,1,1) = pack("C", 99);              # corrupt the length byte
my $crc = 0; $crc ^= $_ for unpack('C*', substr($body,0,length($body)-1));
substr($body,length($body)-1,1) = pack("C",$crc); # keep the checksum valid
@got = read_chunks($hash, "\xC0".$body."\xC0");
is_deeply(\@got, [], "frame with a wrong length is discarded, not decoded anyway");

# ---------------------------------------------------------------- 11. garbage in front of a frame
$hash = new_hash();
@got = read_chunks($hash, "\x11\x22" . build_frame("\x03\x04\x00\x05"));
is_deeply(\@got, ["03040005"], "leading garbage is skipped, frame still found");

# ---------------------------------------------------------------- 12. doubled SLIP_END between frames
$hash = new_hash();
@got = read_chunks($hash, build_frame("\x03\x04\x00\x06") . "\xC0" . build_frame("\x03\x04\x00\x07"));
is_deeply(\@got, ["03040006", "03040007"], "extra SLIP_END between frames is tolerated");
