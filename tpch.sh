#!/bin/sh

if [ $# -ne 7 ]; then
  echo "please use: $0 result_dir ip port dbname user pwd row|column|redshift"
  exit 1
fi

RESULTS=$1
IP=$2
PORT=$3
DBNAME=$4
USER=$5
PASSWORD=$6
STORAGE=$7

if [ $STORAGE != 'row' ] && [ $STORAGE != 'column' ] && [ $STORAGE != 'redshift' ]; then
  echo "you must enter { row | column | redshift }"
  exit 1
fi

DEP_CMD="psql"
which $DEP_CMD 
if [ $? -ne 0 ]; then
  echo -e "dep commands: $DEP_CMD not exist."
  exit 1
fi

export PGPASSWORD=$PASSWORD

# delay between stats collections (iostat, vmstat, ...)
DELAY=15

# DSS queries timeout
DSS_TIMEOUT=300000     # seconds

# log
LOGFILE=bench.log

function benchmark_run() {

	mkdir -p $RESULTS

	print_log "store the settings"
	psql -h $IP -p $PORT -U $USER $DBNAME -c "select name,setting from pg_settings" > $RESULTS/settings.log 2> $RESULTS/settings.err

	print_log "preparing TPC-H database"

	# create database, populate it with data and set up foreign keys
	# psql -h $IP -p $PORT -U $USER $DBNAME < dss/tpch-create.sql > $RESULTS/create.log 2> $RESULTS/create.err

        psql -q -A -t -h $IP -p $PORT -U $USER $DBNAME -c "select 1 from region limit 1"
        if [ $? -eq 0 ]; then
          print_log "data loaded already."
        else
          if [ $STORAGE == 'row' ]; then
	    print_log "  loading data"
	    psql -h $IP -p $PORT -U $USER $DBNAME < dss/tpch-load.sql.row > $RESULTS/load.log 2> $RESULTS/load.err

	    print_log "  creating primary keys"
	    psql -h $IP -p $PORT -U $USER $DBNAME < dss/tpch-pkeys.sql.row > $RESULTS/pkeys.log 2> $RESULTS/pkeys.err

	    #print_log "  creating foreign keys"
	    #psql -h $IP -p $PORT -U $USER $DBNAME < dss/tpch-alter.sql > $RESULTS/alter.log 2> $RESULTS/alter.err
          elif [ $STORAGE == 'column' ]; then
            print_log "  loading data"
            psql -h $IP -p $PORT -U $USER $DBNAME < dss/tpch-load.sql.column > $RESULTS/load.log 2> $RESULTS/load.err

            print_log "  creating primary keys"
            psql -h $IP -p $PORT -U $USER $DBNAME < dss/tpch-pkeys.sql.column > $RESULTS/pkeys.log 2> $RESULTS/pkeys.err

            #print_log "  creating foreign keys"
            #psql -h $IP -p $PORT -U $USER $DBNAME < dss/tpch-alter.sql > $RESULTS/alter.log 2> $RESULTS/alter.err
          elif [ $STORAGE == 'redshift' ]; then
            print_log "  create table"
            psql -h $IP -p $PORT -U $USER $DBNAME < dss/tpch-create.sql.redshift > $RESULTS/create.log 2> $RESULTS/create.err

            print_log "  loading data"
            TABLES="customer lineitem nation orders part partsupp region supplier"
            for table in $TABLES
            do
              cat /tmp/dss-data/${table}.csv | psql -h $IP -p $PORT -U $USER $DBNAME -c "copy ${table} from stdin" >> $RESULTS/load.log 2>> $RESULTS/load.err
            done

            #print_log "  creating foreign keys"
            #psql -h $IP -p $PORT -U $USER $DBNAME < dss/tpch-alter.sql > $RESULTS/alter.log 2> $RESULTS/alter.err
          fi

	  print_log "  creating indexes"
	  psql -h $IP -p $PORT -U $USER $DBNAME < dss/tpch-index.sql > $RESULTS/index.log 2> $RESULTS/index.err

	  print_log "  analyzing"
	  psql -h $IP -p $PORT -U $USER $DBNAME -c "analyze" > $RESULTS/analyze.log 2> $RESULTS/analyze.err
        fi

	print_log "running TPC-H benchmark"

	benchmark_dss $RESULTS

	print_log "finished TPC-H benchmark"

}

function benchmark_dss() {

	mkdir -p $RESULTS

	mkdir $RESULTS/vmstat-s $RESULTS/vmstat-d $RESULTS/explain $RESULTS/results $RESULTS/errors

	# get bgwriter stats
	psql -h $IP -p $PORT -U $USER $DBNAME -c "SELECT * FROM pg_stat_bgwriter" > $RESULTS/stats-before.log 2>> $RESULTS/stats-before.err
	psql -h $IP -p $PORT -U $USER $DBNAME -c "SELECT * FROM pg_stat_database WHERE datname = '$DBNAME'" >> $RESULTS/stats-before.log 2>> $RESULTS/stats-before.err

	vmstat -s > $RESULTS/vmstat-s-before.log 2>&1
	vmstat -d > $RESULTS/vmstat-d-before.log 2>&1

	print_log "running queries defined in TPC-H benchmark"

	for n in `seq 1 22`
	do

		q="dss/queries/$n.sql"
		qe="dss/queries/$n.explain.sql"

		if [ -f "$q" ]; then

			print_log "  running query $n"

			echo "======= query $n =======" >> $RESULTS/data.log 2>&1;

			print_log "run explain"
			psql -h $IP -p $PORT -U $USER $DBNAME < $qe > $RESULTS/explain/$n 2>> $RESULTS/explain.err

			vmstat -s > $RESULTS/vmstat-s/before-$n.log 2>&1
			vmstat -d > $RESULTS/vmstat-d/before-$n.log 2>&1

			print_log "run the query on background"
			/usr/bin/time -a -f "$n = %e" -o $RESULTS/results.log psql -h $IP -p $PORT -U $USER $DBNAME < $q > $RESULTS/results/$n 2> $RESULTS/errors/$n &

			# wait up to the given number of seconds, then terminate the query if still running (don't wait for too long)
			for i in `seq 0 $DSS_TIMEOUT`
			do

				# the query is still running - check the time
				if [ -d "/proc/$!" ]; then

					# the time is over, kill it with fire!
					if [ $i -eq $DSS_TIMEOUT ]; then

						print_log "    killing query $n (timeout)"

						echo "$q : timeout" >> $RESULTS/results.log
						psql -h $IP -p $PORT -U $USER $DBNAME -c "SELECT pg_terminate_backend(procpid) FROM pg_stat_activity WHERE datname = 'tpch'" >> $RESULTS/queries.err 2>&1;

						# time to do a cleanup
						sleep 10;

						# just check how many backends are there (should be 0)
						psql -h $IP -p $PORT -U $USER $DBNAME -c "SELECT COUNT(*) AS tpch_backends FROM pg_stat_activity WHERE datname = 'tpch'" >> $RESULTS/queries.err 2>&1;

					else
						# the query is still running and we have time left, sleep another second
						sleep 1;
					fi;

				else

					# the query finished in time, do not wait anymore
					print_log "    query $n finished OK ($i seconds)"
					break;

				fi;

			done;

			vmstat -s > $RESULTS/vmstat-s/after-$n.log 2>&1
			vmstat -d > $RESULTS/vmstat-d/after-$n.log 2>&1

		fi;

	done;

	# collect stats again
	psql -h $IP -p $PORT -U $USER $DBNAME -c "SELECT * FROM pg_stat_bgwriter" > $RESULTS/stats-after.log 2>> $RESULTS/stats-after.err
	psql -h $IP -p $PORT -U $USER $DBNAME -c "SELECT * FROM pg_stat_database WHERE datname = '$DBNAME'" >> $RESULTS/stats-after.log 2>> $RESULTS/stats-after.err

	vmstat -s > $RESULTS/vmstat-s-after.log 2>&1
	vmstat -d > $RESULTS/vmstat-d-after.log 2>&1

}

function stat_collection_start()
{

	local RESULTS=$1

	# run some basic monitoring tools (iotop, iostat, vmstat)
	for dev in $DEVICES
	do
		iostat -t -x /dev/$dev $DELAY >> $RESULTS/iostat.$dev.log &
	done;

	vmstat $DELAY >> $RESULTS/vmstat.log &

}

function stat_collection_stop()
{

	# wait to get a complete log from iostat etc. and then kill them
	sleep $DELAY

	for p in `jobs -p`; do
		kill $p;
	done;

}

function print_log() {

	local message=$1

	echo `date +"%Y-%m-%d %H:%M:%S"` "["`date +%s`"] : $message" >> $RESULTS/$LOGFILE;

}

mkdir $RESULTS;

# start statistics collection
stat_collection_start $RESULTS

# run the benchmark
benchmark_run $RESULTS $DBNAME $USER

# stop statistics collection
stat_collection_stop
