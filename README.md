# wunderground-history-fetch
Download historical weather data from Weather Underground.
Weather Underground no longer allows direct download of weather data even though individuals with personal weather stations (PWS) have contributed their data to WU.
This script scrapes data from the WU's "dashboard" page for a PWS.
It won't work for other types of stations with different page layouts, although it could easily be modified.
Requires: Perl with modules HTML::TreeBuilder, Date::Manip, and LWP::UserAgent
