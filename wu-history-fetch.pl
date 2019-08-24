#!/usr/bin/perl

# extract historical weather data from weather underground pws page

# Usage:
#  wu-history-fetch StationName StartDate [EndDate]
#   StationName - such as KCALOSBA4
#   StartDate - yyyy/mm/dd
#   End Date - optional, today if omitted

# write output to two files
#  wu-fetch-summary-yyyy-mmdd-hhmmss
#  wu-fetch-details-yyyy-mmdd-hhmmss
# errors to
#  wu-fetch-log-yyyy-mmdd-hhmmss.log

# units are removed
# logic to remove both English and Metric units are included
#  but html is always in English units for me in USA, regardless of
#  display setting or station location
#  I suspect WU always serves data in F,in instead of C,mm,km/h,hPa
#  but I can't be certain
# Solar radiation is always in watts per square meter
#  I don't try to include superscipt-2 in this code
#  I just delete 'w/m' and one character more

# time is converted from AM/PM to 24-hour format

# there are four tables on the page:
#  summary table class="summary-table"
#   high, low, average of
#    temperature
#    dew point
#    humidity
#    precipitation (high only)
#  summary table class="summary-table"
#   high, low, average of
#    wind speed
#    wind gust
#    wind direction (avg only)
#    pressure (high, low only)
#  table of observations class="history-table mobile-table"
#   has only observation times when run on desktop
#   ignore this
#  table of observations class="history-table mobile-table"
#   time
#   temperature
#   dew point
#   humidity
#   wind direction
#   wind speed
#   wind gust
#   pressure
#   precipitation rate
#   precipitation accumulation
#   uv
#   solar


# both of these are possible:
#  zero tables if no data available
#  two tables if detailed observations unavailable

# convert wind directions to degrees

use strict;

use HTML::TreeBuilder;
use Date::Manip;
use LWP::UserAgent;

use constant FIRST_TABLE => 0;
use constant SECOND_TABLE => 1;
use constant FOURTH_TABLE => 3;

# station name and dates
my $station = $ARGV[0];
my $initialDateStr = $ARGV[1];
my $lastDateStr = $ARGV[2];

if (!$station) {
  print STDERR "Missing station name\n";
  &doHelp;
  die;
}

if (!$initialDateStr
    || ($initialDateStr !~ m:\d{4}/\d{2}/\d{2}:)) {
  print STDERR "Initial date missing or not in required format\n",
    " Leading zeros are required for month and day\n";
  &doHelp;
  die;
}

if ($lastDateStr
    && ($lastDateStr !~ m:\d{4}/\d{2}/\d{2}:)) {
  print STDERR "Last date not in required format\n",
    " Leading zeros are required for month and day\n";
  &doHelp;
  die;
}

sub doHelp {
  print <<'EOM';
Usage: $0 StationName InitialDate [LastDate]
  Dates must be of the form "yyyy/mm/dd".
  Leading zeros are required.
  If LastDate is omitted, today's date will be used.
EOM
  return;
}

my %directions
  = (
     'North', '0',
     'NNE', '22.5',
     'NE', '45',
     'ENE', '67.5',
     'East', '90',
     'ESE', '112.5',
     'SE', '135',
     'SSE', '157.5',
     'South', '180',
     'SSW', '202.5',
     'SW', '225',
     'WSW', '247.5',
     'West', '270',
     'WNW', '292.5',
     'NW', '315',
     'NNW', '337.5',
    );

# define the empty summary boxes
# true for all stations
# others may be empty
#  no anemometer, for example
my @emptySummBox
  = (
     0, 0, 0,			# temp: high, low, avg
     0, 0, 0,			# dew point: high, low, avg
     0, 0, 0,			# humidity: high, low, avg
     0, 1, 1,			# precip: value (in high column), (two empty fields)
     0, 0, 0,			# wind speed: high, low, avg
     0, 1, 0,			# wind gust: high, (empty field), avg
     1, 1, 0,			# (two empty fields), wind direction (in avg field)
     0, 0, 1,			# pressure: high, low, (empty field)
    );

my %emptySummBox
  = (
     10, 1,
     11, 1,
     16, 1,
     18, 1,
     19, 1,
     23, 1,
    );

# empty details boxes
#  program this to determine what data you want
#   0 means keep: insert comma, value
#   1 means skip: insert comma
#   2 for time field, skip with no comma: insert nothing
my @emptyDetailsBox
  = (2,				# time, special processing
     0,				# temperature
     0,				# dew point
     0,				# humidity
     0,				# wind direction
     0,				# wind speed
     0,				# wind gust
     0,				# pressure
     0,				# precipitation rate
     0,				# precipitation accumulation
     1,				# UV
     1,				# solar
    );

# these are in Date::Manip format
my $initialDate = ParseDate($initialDateStr);
my $lastDate;

my $todayDate = ParseDate(sprintf("%4d/%02d/%02d",
				  (localtime())[5]+1900,
				  (localtime())[4]+1,
				  (localtime())[3]));
if ($lastDateStr) {
  $lastDate = ParseDate($lastDateStr);
}
else {
  $lastDate = $todayDate;
}

my $nextDayDelta = ParseDateDelta("1 day");
my $currentDate;

# log and output files
my $startTime = time();
my $startTimeString = localtime($startTime);
my @myTime = localtime($startTime);
my $logName = "wu-fetch-log-";
$logName = sprintf("%s%04d-%02d%02d-%02d%02d%02d.log",
		   $logName,
		   $myTime[5]+1900, $myTime[4]+1, $myTime[3],
		   $myTime[2], $myTime[1], $myTime[0]);

my $summaryName = "wu-fetch-summary-";
$summaryName = sprintf("%s%04d-%02d%02d-%02d%02d%02d",
		   $summaryName,
		   $myTime[5]+1900, $myTime[4]+1, $myTime[3],
		   $myTime[2], $myTime[1], $myTime[0]);

my $detailsName = "wu-fetch-details-";
$detailsName = sprintf("%s%04d-%02d%02d-%02d%02d%02d",
		   $detailsName,
		   $myTime[5]+1900, $myTime[4]+1, $myTime[3],
		   $myTime[2], $myTime[1], $myTime[0]);

if (!open(LOG, ">$logName")) {
  # quit
  my $retCode = $!;
  die "failure opening log file: $retCode\n";
}

if (!open(SUMMARY, ">$summaryName")) {
  my $retCode = $!;
  die "failure opening summary file: $retCode\n";
}
if (!open(DETAILS, ">$detailsName")) {
  # quit
  my $retCode = $!;
  die "failure opening details file: $retCode\n";
}

# unbuffer stdout and log file so we can watch progress
$|++;
my $oldfh = select(LOG);
$|++;
select($oldfh);

logit("Start: $logName\n");

# followed this by yyyy-mm-dd/yyyy-mm-dd/daily
my $wuUrlBase = "https://www.wunderground.com/dashboard/pws/$station/table/";
my $userAgent = LWP::UserAgent->new;
$userAgent->agent("Mozilla/8.0");

# for some unknown reason, look_down doesn't find all the tables
#  or all the table rows, so we use tagname_map

$currentDate = $initialDate;
while (Date_Cmp($currentDate, $lastDate) < 1) {
  my $currDateStr = UnixDate($currentDate, "%Y-%m-%d");
  logit("$currDateStr\n");

  my $wuUrl = "$wuUrlBase/$currDateStr/$currDateStr/daily";
  my $request = HTTP::Request->new(GET => $wuUrl);
  my $result = $userAgent->request($request);
  if ($result->is_success) {
    my $tree;			# full page
    my $tagMap;			# reused for each map
    my @tables;			# should have four or two (no observations) or zero (no data)
    my $tableBodyTree;		# reused for each table
    my @tableRows;		# reused for each table
    my $rowHead;		# to check for correct summary table
    my $outputLine;		# values for current date or time - reused
    $outputLine = $currDateStr;

    $tree = HTML::TreeBuilder->new;
    $tree->ignore_unknown(0);
    $tree->warn(1);
    $tree->parse($result->decoded_content) || die;

    $tagMap = $tree->tagname_map();
    if (!defined %$tagMap{'table'}) {
      logit("No data for $currDateStr\n");
      next;
    }
    @tables = @{ %$tagMap{'table'} };
    if ((scalar(@tables) != 4) && (scalar(@tables) != 2)) {
      logit("Table count (", scalar(@tables),
	") wrong at $currDateStr\n");
      next;
    }

    # skip the empty boxes in the summary tables
    #  wunderground places '--' in them but is it ever anywhere else?
    #  count where we are to be sure data goes in the right place

    # first table is first summary table
    # check the class
    if ($tables[FIRST_TABLE]->attr('class') ne 'summary-table') {
      logit("Unexpected class (",
	$tables[FIRST_TABLE]->attr('class'),
	"), expecting first summary at $currDateStr\n");
      next;
    }
    # find the body, then the rows
    # append each value to output line
    $tableBodyTree = $tables[FIRST_TABLE]->look_down('_tag', 'tbody') || die;
    $tagMap = $tableBodyTree->tagname_map();
    @tableRows = @{ %$tagMap{'tr'} }; # find all the rows
    # check header of first row
    $rowHead = $tableRows[0]->look_down('_tag', 'th');
    if ($rowHead->as_text() ne 'Temperature') {
      logit("unexpected row header first summary (",
	$rowHead->as_text(),
	"), expecting 'Temperature' at $currDateStr\n");
      next;
    }
    my $outIdx = 0;
    foreach my $row (@tableRows) {
      my @tds = $row->look_down('_tag', 'td');
      foreach (@tds) {
	my $text = $_->as_text();
	$text =~ s/\xa0//;
	$text =~ s/in//;
	$text =~ s/mm//;
	$text =~ s:km/h::;
	$text =~ s/hPa//;
	$text =~ s/mph//;
	$text =~ s/[CF% ]//g;
	$text =~ s:w/m.::;
	if ($emptySummBox{$outIdx}) { # no value here, skip it
	  if ($text ne '--') {
	    logit("Unexpected value ($text) at summary idx $outIdx at $currDateStr\n");
	  }
	}
	else {
	  $outputLine .= ",$text";
	}
	$outIdx++;
      }
    }

    # second table is second summary table
    # check the class
    if ($tables[SECOND_TABLE]->attr('class') ne 'summary-table') {
      logit("Unexpected class (",
	$tables[SECOND_TABLE]->attr('class'),
	"), expecting second summary at $currDateStr\n");
      next;
    }
    # find the body, then the rows
    $tableBodyTree = $tables[SECOND_TABLE]->look_down('_tag', 'tbody') || die;
    $tagMap = $tableBodyTree->tagname_map();
    @tableRows = @{ %$tagMap{'tr'} }; # find all the rows
    # check header of first row
    $rowHead = $tableRows[0]->look_down('_tag', 'th');
    if ($rowHead->as_text() ne 'Wind Speed') {
      logit("unexpected row header second summary (",
	    $rowHead->as_text(),
	    "), expecting 'Wind Speed' at $currDateStr\n");
      next;
    }
    foreach my $row (@tableRows) {
      my @tds = $row->look_down('_tag', 'td');
      foreach (@tds) {
	my $text = $_->as_text();
	$text =~ s/\xa0//;
	$text =~ s/in//;
	$text =~ s/mm//;
	$text =~ s:km/h::;
	$text =~ s/hPa//;
	$text =~ s/mph//;
	$text =~ s/[CF% ]//g;
	$text =~ s:w/m.::;
	if (defined $directions{$text}) {
	  $text = $directions{$text};
	}
	if ($emptySummBox{$outIdx}) { # no output from here
	  if ($text ne '--') {
	    logit("Unexpected value ($text) at summary idx $outIdx at $currDateStr\n");
	  }
	}
	else {
	  $outputLine .= ",$text";
	}
	$outIdx++;
      }
    }
    print SUMMARY "$outputLine\n";
    next if (scalar(@tables) < 3);

    # ignore third table - it's for mobile

    # fourth table has details
    # check the class
    if ($tables[FOURTH_TABLE]->attr('class') ne 'history-table desktop-table') {
      logit("Unexpected class (",
	$tables[FOURTH_TABLE]->attr('class'),
	"), expecting 'history-table desktop-table' at $currDateStr\n");
      next;
    }
    # find the body, then the rows
    $tableBodyTree = $tables[FOURTH_TABLE]->look_down('_tag', 'tbody') || die;
    $tagMap = $tableBodyTree->tagname_map();
    @tableRows = @{ %$tagMap{'tr'} }; # find all the rows
    foreach my $row (@tableRows) {
      $outputLine = $currDateStr;
      my @tds = $row->look_down('_tag', 'td');
      if (scalar(@tds) != 12) {
	if (scalar(@tds) > 0) {
	  logit("Too few tds in details at $currDateStr at ",
		$tds[0]->as_text(), "\n");
	}
	else {
	  logit("No tds in details at $currDateStr\n");
	}
	next;
      }
      # convert time to 24-hour
      my $timeStr = $tds[0]->as_text();
      my $hr;
      my $min;
      ($hr, $min) = ($timeStr =~ /^(\d+):(\d+)/);
      $hr = 0 if ($hr == 12);	# hr is now 0..11
      $hr += 12 if ($timeStr =~ /PM/);
      $timeStr = sprintf("%d:%s", $hr, $min);
      $outputLine = "$currDateStr,$timeStr";
      my $outIdx = 0;
      foreach (@tds) {
    	my $text = $_->as_text();
	$text =~ s/\xa0//;
	$text =~ s/in//;
	$text =~ s/mm//;
	$text =~ s:km/h::;
	$text =~ s/hPa//;
	$text =~ s/mph//;
	$text =~ s/[CF% ]//g;
	$text =~ s:w/m.::;
	$text =~ s/--//;	# missing reading is '--'
	if (defined $directions{$text}) {
	  $text = $directions{$text};
	}
	if ($emptyDetailsBox[$outIdx]) { # no value here, skip it
	  if (($emptyDetailsBox[$outIdx] != 2) && ($text ne '')) { # time is not empty
	    logit("Unexpected value ($text) at details idx $outIdx at $currDateStr $timeStr\n");
	  }
	}
	else {
	  $outputLine .= ",$text";
	}
	$outIdx++;
      }
      print DETAILS "$outputLine\n";
    }
  }
  else {
    logit("GET failed for $currDateStr\n");
  }
}
continue {
  $currentDate = DateCalc($currentDate, $nextDayDelta);
}

my $endTime = time();
my @myEndTime = localtime($endTime);
my $endNote = sprintf("Exit at %04d-%02d%02d-%02d%02d%02d...\n",
		      $myEndTime[5]+1900, $myEndTime[4]+1, $myEndTime[3],
		      $myEndTime[2], $myEndTime[1], $myEndTime[0]);
logit($endNote);

close(SUMMARY);
close(DETAILS);
close(LOG);


# write to stdout and to LOG
sub logit {
  my $line;
  while ($line = shift(@_)) {
    print $line;
    print LOG $line;
  }
}
