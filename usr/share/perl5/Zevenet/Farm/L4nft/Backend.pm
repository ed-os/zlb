#!/usr/bin/perl
###############################################################################
#
#    Zevenet Software License
#    This file is part of the Zevenet Load Balancer software package.
#
#    Copyright (C) 2014-today ZEVENET SL, Sevilla (Spain)
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Affero General Public License as
#    published by the Free Software Foundation, either version 3 of the
#    License, or any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Affero General Public License for more details.
#
#    You should have received a copy of the GNU Affero General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################

use strict;

my $configdir = &getGlobalConfiguration( 'configdir' );

=begin nd
Function: setL4FarmServer

	Edit a backend or add a new one if the id is not found

Parameters:
	farmname - Farm name
	id - Backend id
	rip - Backend IP
	port - Backend port
	weight - Backend weight. The backend with more weight will manage more connections
	priority - The priority of this backend (between 1 and 9). Higher priority backends will be used more often than lower priority ones
	maxconn - Maximum connections for the given backend

Returns:
	Integer - return 0 on success, -1 on NFTLB failure or -2 on IP duplicated.

Returns:
	Scalar - 0 on success or other value on failure
	FIXME: Stop returning -2 when IP duplicated, nftlb should do this
=cut

sub setL4FarmServer    # ($farm_name,$ids,$rip,$port,$weight,$priority,$maxconn)
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my ( $farm_name, $ids, $rip, $port, $weight, $priority, $max_conns ) = @_;

	#	require Zevenet::FarmGuardian;
	require Zevenet::Farm::L4xNAT::Config;
	require Zevenet::Farm::L4xNAT::Action;
	require Zevenet::Farm::Backend;
	require Zevenet::Netfilter;

	&zenlog(
		"setL4FarmServer << farm_name:$farm_name ids:$ids rip:$rip port:$port weight:$weight priority:$priority max_conns:$max_conns"
	) if &debug;

	my $farm_filename = &getFarmFile( $farm_name );
	my $mark          = &getNewMark( $farm_name );
	my $output        = 0;

	if ( $weight == 0 )
	{
		$weight = 1;
	}

	if ( $priority == 0 )
	{
		$priority = 1;
	}

	# load the configuration file first if the farm is down
	my $f_ref = &getL4FarmStruct( $farm_name );
	if ( $f_ref->{ status } ne "up" )
	{
		my $out = &loadNLBFarm( $farm_name );
		if ( $out != 0 )
		{
			return $out;
		}
	}

	my $exists = &getFarmServer( $f_ref->{ servers }, $ids );

	# It's a backend modification
	if ( $exists )
	{
		$mark = $exists->{ tag };
	}

	$exists = &getFarmServer( $f_ref->{ servers }, $rip, "rip" );
	return -2 if ( $exists && ( $exists->{ id } ne $ids ) );

	$output = &httpNLBRequest(
		{
		   farm       => $farm_name,
		   configfile => "$configdir/$farm_filename",
		   method     => "PUT",
		   uri        => "/farms",
		   body =>
			 qq({"farms" : [ { "name" : "$farm_name", "backends" : [ { "name" : "bck$ids", "ip-addr" : "$rip", "ports" : "", "weight" : "$weight", "priority" : "$priority", "mark" : "$mark", "state" : "up" } ] } ] })
		}
	);

	&setL4BackendRule( "add", $f_ref, $mark );

	return $output;
}

=begin nd
Function: runL4FarmServerDelete

	Delete a backend from a l4 farm

Parameters:
	backend - Backend id
	farmname - Farm name

Returns:
	Scalar - 0 on success or other value on failure

=cut

sub runL4FarmServerDelete    # ($ids,$farm_name)
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my ( $ids, $farm_name ) = @_;

	require Zevenet::Farm::L4xNAT::Config;
	require Zevenet::Farm::L4xNAT::Action;
	require Zevenet::Netfilter;

	my $farm_filename = &getFarmFile( $farm_name );
	my $output        = 0;
	my $mark          = "0x0";

	# load the configuration file first if the farm is down
	my $f_ref = &getL4FarmStruct( $farm_name );
	if ( $f_ref->{ status } ne "up" )
	{
		my $out = &loadNLBFarm( $farm_name );
		if ( $out != 0 )
		{
			return $out;
		}
	}

	$output = &httpNLBRequest(
							   {
								 farm       => $farm_name,
								 configfile => "$configdir/$farm_filename",
								 method     => "DELETE",
								 uri        => "/farms/$farm_name/backends/bck$ids",
								 body       => undef
							   }
	);

	foreach my $server ( @{ $f_ref->{ servers } } )
	{
		if ( $server->{ id } eq $ids )
		{
			$mark = $server->{ tag };
			last;
		}
	}

	&setL4BackendRule( "del", $f_ref, $mark );
	&delMarks( "", $mark );

	return $output;
}

=begin nd
Function: setL4FarmBackendStatus

	Set backend status for a l4 farm

Parameters:
	farmname - Farm name
	backend - Backend id
	status - Backend status. The possible values are: "up" or "down"

Returns:
	Integer - 0 on success or other value on failure

=cut

sub setL4FarmBackendStatus    # ($farm_name,$backend,$status)
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my ( $farm_name, $backend, $status ) = @_;

	require Zevenet::Farm::L4xNAT::Config;
	require Zevenet::Farm::L4xNAT::Action;

	my $farm_filename = &getFarmFile( $farm_name );

	$status = 'off'  if ( $status eq "maintenance" );
	$status = 'down' if ( $status eq "fgDOWN" );

	# load the configuration file first if the farm is down
	my $f_ref = &getL4FarmStruct( $farm_name );
	if ( $f_ref->{ status } ne "up" )
	{
		my $out = &loadNLBFarm( $farm_name );
		if ( $out != 0 )
		{
			return $out;
		}
	}

	my $output = &httpNLBRequest(
		{
		   farm       => $farm_name,
		   configfile => "$configdir/$farm_filename",
		   method     => "PUT",
		   uri        => "/farms",
		   body =>
			 qq({"farms" : [ { "name" : "$farm_name", "backends" : [ { "name" : "bck$backend", "state" : "$status" } ] } ] })
		}
	);

	return $output;
}

=begin nd
Function: getL4FarmServers

	 Get all backends and their configuration

Parameters:
	farmname - Farm name

Returns:
	Array - array of hash refs of backend struct

=cut

sub getL4FarmServers    # ($farm_name)
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $farm_name = shift;

	my $farm_filename = &getFarmFile( $farm_name );

	open my $fd, '<', "$configdir/$farm_filename";
	chomp ( my @content = <$fd> );
	close $fd;

	return &_getL4FarmParseServers( \@content );
}

=begin nd
Function: _getL4FarmParseServers

	Return the list of backends with all data about a backend in a l4 farm

Parameters:
	config - plain text server list

Returns:
	backends array - array of backends structure
		\%backend = { $id, $alias, $family, $ip, $port, $tag, $weight, $priority, $status, $rip = $ip }

=cut

sub _getL4FarmParseServers
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $config = shift;
	my $stage  = 0;
	my $server;
	my @servers;

	require Zevenet::Farm::L4xNAT::Config;
	my $fproto = &_getL4ParseFarmConfig( 'proto', undef, $config );

	foreach my $line ( @{ $config } )
	{
		if ( $line =~ /\"farms\"/ )
		{
			$stage = 1;
		}

		if ( $line =~ /\"backends\"/ )
		{
			$stage = 2;
		}

		if ( $stage == 2 && $line =~ /\{/ )
		{
			$stage = 3;
			undef $server;
		}

		if ( $stage == 3 && $line =~ /\}/ )
		{
			$stage = 2;
			push ( @servers, $server );
		}

		if ( $stage == 3 && $line =~ /\"name\"/ )
		{
			my @l = split /"/, $line;
			my $index = $l[3];
			$index =~ s/bck//;
			$server->{ id }        = $index + 0;
			$server->{ port }      = undef;
			$server->{ tag }       = "0x0";
			$server->{ max_conns } = 0;
		}

		if ( $stage == 3 && $line =~ /\"ip-addr\"/ )
		{
			my @l = split /"/, $line;
			$server->{ ip }  = $l[3];
			$server->{ rip } = $l[3];
		}

		if ( $stage == 3 && $line =~ /\"port\"/ )
		{
			$server->{ port } = "";    # TODO Not supported yet

			require Zevenet::Net::Validate;
			if ( $server->{ port } ne '' && $fproto ne 'all' )
			{
				if ( &ipversion( $server->{ rip } ) == 4 )
				{
					$server->{ rip } = "$server->{ip}\:$server->{port}";
				}
				elsif ( &ipversion( $server->{ rip } ) == 6 )
				{
					$server->{ rip } = "[$server->{ip}]\:$server->{port}";
				}
			}
		}

		if ( $stage == 3 && $line =~ /\"weight\"/ )
		{
			my @l = split /"/, $line;
			$server->{ weight } = $l[3] + 0;
		}

		if ( $stage == 3 && $line =~ /\"priority\"/ )
		{
			my @l = split /"/, $line;
			$server->{ priority } = $l[3] + 0;
		}

		if ( $stage == 3 && $line =~ /\"mark\"/ )
		{
			my @l = split /"/, $line;
			$server->{ tag } = $l[3];
		}

		if ( $stage == 3 && $line =~ /\"state\"/ )
		{
			my @l = split /"/, $line;
			$server->{ status } = $l[3];
			$server->{ status } = "maintenance" if ( $server->{ status } eq "off" );
			$server->{ status } = "fgDOWN" if ( $server->{ status } eq "down" );
		}
	}

	return \@servers;
}

=begin nd
Function: getL4ServerWithLowestPriority

	Look for backend with the lowest priority

Parameters:
	farm - Farm hash ref. It is a hash with all information about the farm

Returns:
	hash ref - reference to the selected server for prio algorithm

=cut

sub getL4ServerWithLowestPriority    # ($farm)
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $farm = shift;                # input: farm reference

	my $prio_server;    # reference to the selected server for prio algorithm

	foreach my $server ( @{ $$farm{ servers } } )
	{
		if ( $$server{ status } eq 'up' )
		{
			# find the lowest priority server
			$prio_server = $server if not defined $prio_server;
			$prio_server = $server if $$prio_server{ priority } > $$server{ priority };
		}
	}

	return $prio_server;
}

=begin nd
Function: setL4FarmBackendMaintenance

	Enable the maintenance mode for backend

Parameters:
	farmname - Farm name
	backend - Backend id
	mode - Maintenance mode, the options are: drain, the backend continues working with
	  the established connections; or cut, the backend cuts all the established
	  connections

Returns:
	Integer - 0 on success or other value on failure

=cut

sub setL4FarmBackendMaintenance    # ( $farm_name, $backend )
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my ( $farm_name, $backend, $mode ) = @_;

	if ( $mode eq "cut" )
	{
		# TODO: Remove persistence
		#&setL4FarmBackendsSessionsRemove( $farm_name, $backend );

		# remove conntrack
		my $farm   = &getL4FarmStruct( $farm_name );
		my $server = $$farm{ servers }[$backend];
		&resetL4FarmBackendConntrackMark( $server );
	}

	return &setL4FarmBackendStatus( $farm_name, $backend, 'maintenance' );
}

=begin nd
Function: setL4FarmBackendNoMaintenance

	Disable the maintenance mode for backend

Parameters:
	farmname - Farm name
	backend - Backend id

Returns:
	Integer - 0 on success or other value on failure

=cut

sub setL4FarmBackendNoMaintenance
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my ( $farm_name, $backend ) = @_;

	return &setL4FarmBackendStatus( $farm_name, $backend, 'up' );
}

=begin nd
Function: getL4BackendsWeightProbability

	Get probability for every backend

Parameters:
	farm - Farm hash ref. It is a hash with all information about the farm

Returns:
	none - .

=cut

sub getL4BackendsWeightProbability
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $farm = shift;    # input: farm reference

	my $weight_sum = 0;

	&doL4FarmProbability( $farm );    # calculate farm weight sum

	foreach my $server ( @{ $$farm{ servers } } )
	{
		# only calculate probability for servers running
		if ( $$server{ status } eq 'up' )
		{
			my $delta = $$server{ weight };
			$weight_sum += $$server{ weight };
			$$server{ prob } = $weight_sum / $$farm{ prob };
		}
		else
		{
			$$server{ prob } = 0;
		}
	}
}

# reset connection tracking for a backend
# used in udp protocol
# called by: refreshL4FarmRules, runL4FarmServerDelete
sub resetL4FarmBackendConntrackMark
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $server = shift;

	my $conntrack = &getGlobalConfiguration( 'conntrack' );
	my $cmd       = "$conntrack -D -m $server->{ tag }";

	&zenlog( "running: $cmd" ) if &debug();

	# return_code = 0 -> deleted
	# return_code = 1 -> not found/deleted
	# WARNIG: STDOUT must be null so cherokee does not receive this output
	# as http headers.
	my $return_code = system ( "$cmd >/dev/null 2>&1" );

	if ( &debug() )
	{
		if ( $return_code )
		{
			&zenlog( "Connection tracking for $server->{ vip } not found." );
		}
		else
		{
			&zenlog( "Connection tracking for $server->{ vip } removed." );
		}
	}

	return $return_code;
}

=begin nd
Function: getL4FarmBackendAvailableID

	Get next available backend ID

Parameters:
	farmname - farm name

Returns:
	integer - .

=cut

sub getL4FarmBackendAvailableID
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $farmname = shift;

	require Zevenet::Farm::Backend;

	my $backends  = &getL4FarmServers( $farmname );
	my $nbackends = $#{ $backends } + 1;

	for ( my $id = 0 ; $id < $nbackends ; $id++ )
	{
		my $exists = &getFarmServer( $backends, $id );
		return $id if ( !$exists );
	}

	return $nbackends;
}

=begin nd
Function: setL4BackendRule

	Add or delete the route rule according to the backend mark.

Parameters:
	action - "add" to create the mark or "del" to remove it.
	farm_ref - farm reference.
	mark - backend mark to apply in the rule.

Returns:
	integer - 0 if successful, otherwise error.

=cut

sub setL4BackendRule
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $action   = shift;
	my $farm_ref = shift;
	my $mark     = shift;

	return -1
	  if (    $action != /add|del/
		   || !defined $farm_ref
		   || $mark eq ""
		   || $mark eq "0x0" );

	require Zevenet::Net::Util;
	require Zevenet::Net::Route;

	my $vip_if_name = &getInterfaceOfIp( $farm_ref->{ vip } );
	my $vip_if      = &getInterfaceConfig( $vip_if_name );
	my $table_if =
	  ( $vip_if->{ type } eq 'virtual' ) ? $vip_if->{ parent } : $vip_if->{ name };

	return &setRule( $action, $vip_if, $table_if, "", "$mark/0x7fffffff" );
}

1;
