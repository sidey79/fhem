# Minimal FHEM stub so that 83_KLF200.pm can be loaded and exercised
# outside of a running FHEM instance. Only used by the tests next to it.
package main;
use strict;
use warnings;

use vars qw($readingFnAttributes %attr %defs %modules %data);
$readingFnAttributes = "";

our %READINGS;      # name -> { reading => value }
our @TIMERS;        # { at => , fn => , hash => }
our @WRITTEN;       # raw bytes handed to DevIo_SimpleWrite
our @LOG;           # [ level, text ]
our @READ_CHUNKS;   # queued results for DevIo_SimpleRead
our $NOW = 1000;

sub gettimeofday { return $NOW }
sub Log3 { my ($h,$l,$t)=@_; push @LOG, [$l,$t]; return }
sub FmtDateTime { return "now" }

sub ReadingsVal {
  my ($name,$reading,$default)=@_;
  return $default if(!defined($READINGS{$name}) || !defined($READINGS{$name}{$reading}));
  return $READINGS{$name}{$reading};
}
sub AttrVal {
  my ($name,$attrName,$default)=@_;
  return $default if(!defined($attr{$name}) || !defined($attr{$name}{$attrName}));
  return $attr{$name}{$attrName};
}
sub readingsSingleUpdate { my ($h,$r,$v)=@_; $READINGS{$h->{NAME}}{$r}=$v; return }
sub readingsBeginUpdate { return }
sub readingsEndUpdate { return }
sub readingsBulkUpdate { my ($h,$r,$v)=@_; $READINGS{$h->{NAME}}{$r}=$v; return }
sub readingsBulkUpdateIfChanged { my ($h,$r,$v)=@_; $READINGS{$h->{NAME}}{$r}=$v; return }

sub InternalTimer {
  my ($at,$fn,$hash)=@_;
  push @TIMERS, { at=>$at, fn=>$fn, hash=>$hash };
  return;
}
sub RemoveInternalTimer {
  my ($hash,$fn)=@_;
  @TIMERS = grep { !($_->{hash} == $hash && (!defined($fn) || $_->{fn} eq $fn)) } @TIMERS;
  return;
}
# run the timer registered for $fn (and remove it), returns 1 if one was found
sub FireTimer {
  my ($hash,$fn)=@_;
  for my $i (0..$#TIMERS) {
    next if($TIMERS[$i]{fn} ne $fn || $TIMERS[$i]{hash} != $hash);
    my $t = splice(@TIMERS,$i,1);
    no strict 'refs';
    &{$t->{fn}}($t->{hash});
    return 1;
  }
  return 0;
}
sub HasTimer {
  my ($hash,$fn)=@_;
  return scalar(grep { $_->{hash} == $hash && $_->{fn} eq $fn } @TIMERS);
}

sub DevIo_SimpleRead { return shift @READ_CHUNKS }
sub DevIo_SimpleWrite { my ($h,$b)=@_; push @WRITTEN, $b; return }
sub DevIo_IsOpen { my ($h)=@_; return defined($h->{TCPDev}) }
sub DevIo_CloseDev { my ($h)=@_; delete $h->{TCPDev}; return }
sub DevIo_OpenDev { return undef }
sub Dispatch { return "node" }
sub getUniqueId { return "unique" }
sub setKeyValue { return undef }
sub getKeyValue { return (undef, undef) }
sub SetExtensions { return undef }

1;
