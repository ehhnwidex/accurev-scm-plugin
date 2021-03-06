package JenkinsHook;

binmode STDOUT, ":utf8";
use warnings;
use strict;
use Exporter qw(import);
use Scalar::Util qw(looks_like_number);

use File::Copy;
use File::Path qw(make_path);

use utf8;
use JSON qw//;
use JSON;
use Socket;
use LWP::UserAgent;
use URI;
use XML::Simple;

use File::Basename;
use lib dirname(__FILE__);
use AccurevUtils;

our @ISA = qw(Exporter);
our @EXPORT = qw(notifyBuild cacheInputFile);

our @EXPORT_OK = qw(updateCrumb);

sub notifyBuild {
	my (@parameters) = @_;
	my $reason = $parameters[0];
	my $stream = $parameters[1];
	my $depot = $parameters[2];
	my $transaction_num = $parameters[3];
	my $principal = $parameters[4];

	if(not looks_like_number($parameters[3])){
		$transaction_num = 1;
		$principal=$parameters[3];
	}
	
	print "Triggered stream: $stream\n";

	my $url = "localhost:5050";
	my $crumbRequestField = "";
	my $crumb = 1;
	my $jenkinsConfigFile = 'triggers/jenkinsConfig.json';

	if (-e $jenkinsConfigFile) {
		print "Jenkins configuration file found.\n";
		my ($urlFromFile, $crumbFromFile, $crumbRequestFieldFromFile) = readJenkinsConfigFile($jenkinsConfigFile);
		$url = $urlFromFile;
		$crumb = $crumbFromFile;
		$crumbRequestField = $crumbRequestFieldFromFile;

		if(not defined $crumb) {
			print "No crumb detected, obtaining crumb.\n";
			my ($crumbUpdated, $crumbRequestFieldUpdated) = updateCrumb($url);
			print "Updating Jenkins configuration file with newly obtained crumb.\n";
			updateJenkinsConfigFile($jenkinsConfigFile, $crumbUpdated, $crumbRequestFieldUpdated);
			$crumb = $crumbUpdated;
            $crumbRequestField = $crumbRequestFieldUpdated;
		}
	} else {
		print "No Jenkins configuration file found, defaulting to localhost.\n";
	}
  
	my $urlToJenkins ="$url/accurev/notifyCommit/";
    print "Attempting to notify $urlToJenkins \n";
	my $userAgent = LWP::UserAgent->new;
	# Set timeout for post calls to 10 seconds.
	$userAgent->timeout(10);
	if(length $crumb){
		print "adding crumb to header. \n";
		$userAgent->default_header($crumbRequestField => $crumb);
	}
	my $xmlInput = `accurev info -fx`;
	my $accurevInfo = XMLin($xmlInput);

	# WHEN NOT TESTING ON LOCALHOST, USE $accurevInfo->{serverName} FOR HOST
	# Create a post call to the Jenkins server with the information regarding the stream that was promoted from
	if(defined $principal) {
		$principal = "gatingActionPrincipal";
	}
	print "Notifying for: $urlToJenkins \n";
	my $response = $userAgent->post($urlToJenkins, {
		'host' => $accurevInfo->{serverName},
		'port' => $accurevInfo->{serverPort},
		'streams' => $stream,
		'transaction' => $transaction_num,
		'principal' => $principal,
		'reason' => $reason
	});
	if(!messageSucceeded($response->status_line)) {
		print "Invalid crumb, fetching new \n";
		my ($crumbUpdated, $crumbRequestFieldUpdated) = updateCrumb($url);
		updateJenkinsConfigFile($jenkinsConfigFile, $crumbUpdated, $crumbRequestFieldUpdated);
		print "Trying to trigger stream again. \n";
		if(length $crumbUpdated){
			print "adding newly obtained crumb to header. \n";
			$userAgent->default_headers->header($crumbRequestFieldUpdated => $crumbUpdated);
		}
		$response = $userAgent->post($urlToJenkins, {
			'host' => $accurevInfo->{serverName},
			'port' => $accurevInfo->{serverPort},
			'streams' => $stream,
			'transaction' => $transaction_num,
			'principal' => $principal,
			'reason' => $reason
		});
		if(!messageSucceeded($response->status_line)) {
			print "cannot notify build because: ".$response->code." ".$response->message."\n";
			# Change the icon to the result
			my $result = "warning";
			system("accurev setproperty -r -s \"$stream\" streamCustomIcon \"" . generateCustomIcon($result, "", "cannot contact jenkins server: $urlToJenkins") . "\"");
			# Report the result (this must be the last accurev command before exiting the trigger)
			system("accurev setproperty -r -s \"$stream\" stagingStreamResult \"$result\"");
		}
	}
}

sub messageSucceeded {
	my ($response) = @_;
	if(index($response, "200 OK") != -1) {
		print "Message succeeded";
		return 1;
	}
	return 0;
}

sub updateCrumb {
	my ($url) = @_;
	my $urlToJenkinsApi ="$url/crumbIssuer/api/json";
    print "$urlToJenkinsApi \n";
	my $json = JSON->new->utf8;
	my $userAgent = LWP::UserAgent->new;
	my $response = $userAgent->get($urlToJenkinsApi);
	if ($response->is_error) {
        print "cannot obtain crumb because: ".$response->code." ".$response->message."\n";
		return;
	} else {
	    my $responseInJson = $json->decode($response->decoded_content);
	    return ($responseInJson->{'crumb'}, $responseInJson->{'crumbRequestField'});
    }
}

sub readJenkinsConfigFile {
	my ($jenkinsConfigFile) = @_;
	my $json;
	{
		local $/; #Enable 'slurp' mode
		open my $fh, "<", $jenkinsConfigFile or die $!;
		$json = <$fh>;
		close $fh;
	}
	my $jenkinsConfig = decode_json($json);
	my $jenkinsUrl = $jenkinsConfig->{'config'}->{'url'};
	my $crumb = $jenkinsConfig->{'config'}->{'authentication'}->{'crumb'};
	my $crumbRequestField = $jenkinsConfig->{'config'}->{'authentication'}->{'crumbRequestField'};

	return $jenkinsUrl, $crumb, $crumbRequestField;
}

sub updateJenkinsConfigFile {
	my ($jenkinsConfigFile, $crumb, $crumbRequestField) = @_;
	if (-e $jenkinsConfigFile) {
		my $jenkinsConfigJson;
		{
			local $/; #Enable 'slurp' mode
			open my $fh, "<", $jenkinsConfigFile or die $!;
			$jenkinsConfigJson = <$fh>;
			close $fh;
		}
		my $jenkinsConfigJsonDecoded = decode_json($jenkinsConfigJson);

		$jenkinsConfigJsonDecoded->{'config'}->{'authentication'}->{'crumb'} = $crumb;
		$jenkinsConfigJsonDecoded->{'config'}->{'authentication'}->{'crumbRequestField'} = $crumbRequestField;

		my $json = JSON->new->utf8;
		$json = $json->pretty([ 1 ]);

		my $jenkinsConfigUpdated = $json->encode($jenkinsConfigJsonDecoded);

		open(my $fh, ">", $jenkinsConfigFile);
		print $fh $jenkinsConfigUpdated;
		close $fh;
	} else {
		print "$jenkinsConfigFile does not exist";
	}
}

sub cacheInputFile {
	my ($file, $stream, $transaction_num) = @_;
	# copy XML trigger input file to new location
    my $dir = "temp";
    my $filecopy = $dir."/gated_input_file-".$stream."-".$transaction_num.".xml";
    eval { make_path($dir) };
    if ($@) {
       print "Couldn't create $dir: $@";
    }
	print "copying file: $filecopy";
    copy($file, $filecopy);
}