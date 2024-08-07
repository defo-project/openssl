#!/bin/bash

# set -x

# to pick up correct executables and .so's
: ${CODETOP:=$HOME/code/openssl}
export LD_LIBRARY_PATH=$CODETOP
# to pick up the relevant configuration
: ${CFGTOP:=$HOME/code/openssl}
# in case you want to re-use a tmp directory
: ${SCRATCHDIR:=""}
# in case you want to keep output from this run, set this to something
: ${KEEP:=""}
# in case you'd like more detailed gibberish-like output:-)
: ${VERBOSE:=""}
# in case you'd like this public name in ECHConfigs
: ${PNAME:=""}
# to shortcut the loops over all kem,kdf,aead options to just the 1st
# we'll default to doing that for now as different algs v. rarely show
# up anything of interest
: ${SHORTCUT:="yes"}

KEM_STRINGS=(p256 p284 p521 x5519 x448 bogus-kem)
KEM_IDS=(0x10 0x11 0x12 0x20 0x21 0xa0)
NKEMS=${#KEM_IDS[*]}

KDF_STRINGS=(hkdf-sha256 hkdf-sha384 hkdf-sha512 bogus-kdf)
KDF_IDS=(0x01 0x02 0x03 0xa1)
NKDFS=${#KDF_IDS[*]}

AEAD_STRINGS=(aes-123-gcm aes-256-gcm chacha20poly1305 bogus-aead)
AEAD_IDS=(0x01 0x02 0x03 0xa2)
NAEADS=${#AEAD_IDS[*]}

# set which tests to skip - set to "yes" to skip or "no" to do tests
# basic client/server tests for combinations of supported/not and grease
skipbase="no"
# the basic good client/server tests for the range of algs
skipgood="no"
# the tests of various forms of RR/ECHConfig
skiprrs="no"
# the basic bad tests
skipbad="no"
# the session re-use tests
skipsess="no"
# the HRR checks
skiphrr="no"
# the early-data checks
skiped="no"
# the HRR+early-data checks
skiphrred="no"

verbose="no"
if [[ "$VERBOSE" != "" ]]
then
    verbose="yes"
fi

startdir=`/bin/pwd`
scratchdir=""

# catch the ctrl-C used to stop the server and do any clean up needed
cleanup() {
    echo ""
    echo "Cleaning up after ctrl-c"
    # kill off any server running from a previous test
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" != "" ]]
    then
        # exiting without cleanup
        kill $pids
    fi
    # kill off any client running from a previous test
    pids=`ps -ef | grep s_client | grep -v grep | awk '{print $2}'`
    if [[ "$pids" != "" ]]
    then
        # exiting without cleanup
        kill $pids
    fi
    cd $startdir
    if [[ "$scratchdir" != "" ]]
    then
        rm -rf $scratchdir
    fi
    exit 0
}

# check if our build supports ech or not
$CODETOP/apps/openssl ech -help >/dev/null 2>&1
res=$?
if [[ "$res" != "0" ]]
then
    echo "OpenSSL appears to have been build without ECH support - maybe re-build? - exiting"
    exit $res
fi

if [[ "$SCRATCHDIR" != "" && -d $SCRATCHDIR ]]
then
    scratchdir="$SCRATCHDIR"
else
    scratchdir=`/bin/mktemp -d /tmp/ech-agile-XXXX`
    if [[ "$KEEP" == "" ]]
    then
        trap cleanup SIGINT
    fi
fi

if [[ "$verbose" == "yes" ]]
then
    echo "Using $scratchdir"
fi
cd $scratchdir

# the same public_name for all test cases
pname="-public_name example.com"
if [[ "$PNAME" != "" ]]
then
    pname="-public_name $PNAME"
fi

#
# Stage 1 generate keys as needed
#

badcnt=0
goodnt=0
unexpectedcnt=0
baddies=""
for ((kdfind=0 ; kdfind<$NKDFS ; kdfind++))
do
    for ((aeadind=0 ; aeadind<$NAEADS ; aeadind++))
    do
        for ((kemind=0 ; kemind<$NKEMS ; kemind++))
        do
            suite="${KEM_IDS[$kemind]},${KDF_IDS[$kdfind]},${AEAD_IDS[$aeadind]}"
            if [ -f $suite.pem ]
            then
                # if re-using a scratchdir, we'll count that a win...
                goodcnt=$((goodcnt+1))
                continue
            fi
            if [[ "$verbose" == "yes" ]]
            then
                echo "Doing $suite ${KEM_STRINGS[$kemind]},${KDF_STRINGS[$kdfind]},${AEAD_STRINGS[$aeadind]}"
                echo "Running: $CODETOP/apps/openssl ech $pname -pemout $suite.pem -suite $suite"
                $CODETOP/apps/openssl ech $pname -pemout $suite.pem -suite $suite >/dev/null -ech_version 13
            else
                $CODETOP/apps/openssl ech $pname -pemout $suite.pem -suite $suite >/dev/null -ech_version 13 2>&1
            fi
            res=$?
            # count good/bad and compare to expectations
            if [[ "$res" != "1" ]]
            then
                baddies="$baddies $suite/$res"
                badcnt=$((badcnt+1))
                if [[ "$kemind" != "$((NKEMS-1))" && \
                        "$kdfind" != "$((NKDFS-1))" && \
                        "$aeadind" != "$((NAEADS-1))" ]]
                then
                    echo "Unexpected: $suite ${KEM_STRINGS[$kemind]},${KDF_STRINGS[$kdfind]},${AEAD_STRINGS[$aeadind]}"
                    unexpectedcnt=$((unexpectedcnt+1))
                fi
            else
                goodcnt=$((goodcnt+1))
            fi
        done
    done
done

if [[ "$verbose" == "yes" ]]
then
    echo "Key gen: good: $goodcnt, bad: $badcnt, unexpected: $unexpectedcnt"
fi

#
# Stage 2 - simple client/server with each suite combo
#

# First, if needed, we want a fake CA, and TLS server certs etc
# (The "if needed" bit only applies if we re-use a tmpdir.)
if [ ! -d ./cadir ]
then
    if [[ "$verbose" == "yes" ]]
    then
        echo "Making keys/fake CA etc."
        #OBIN=$obin $CODETOP/esnistuff/make-example-ca.sh
        TOP=$CODETOP $CODETOP/esnistuff/make-example-ca.sh
    else
        #OBIN=$obin $CODETOP/esnistuff/make-example-ca.sh >/dev/null 2>&1
        TOP=$CODETOP $CODETOP/esnistuff/make-example-ca.sh >/dev/null 2>&1
    fi
fi

# check stuff worked above
if [ ! -f ./cadir/oe.priv ]
then
    echo "No sign of cadir/oe.priv - exiting"
    exit 11
fi

# make an oddball link to confuse echsvr.sh enough to work...
if [ ! -e esnistuff ]
then
    ln -s . esnistuff
fi

# We'll re-use the PEM files and dervice suites from file names

vparm=""
sleepb4=4
sleepaftr=2
if [[ "$verbose" == "yes" ]]
then
    vparm=" -d "
    # the -v will also get you valgrind...
    # vparm=" -vd "
    # with valgrind you probably also need to wait longer
    # sleepb4=10
    # sleepaftr=8
fi

# kill off any server running from a previous test
pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
if [[ "$pids" != "" ]]
then
    # exiting without cleanup
    kill $pids
fi

if [[ "$skipbase" == "no" ]]
then
    tests="yes-yes no-yes yes-no no-no grease-yes grease-no ignore-trial ignore-yes"
    for atest in $tests
    do
    # pick just one key file to use for this
    file="0x20,0x01,0x01.pem"
    case $atest in
        "yes-yes")
            echo "s_client/s_server base test with ECH, vs. ECH server"
            server_params=" -w -k $scratchdir/$file $vparm "
            client_params=" -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html"
            ;;
        "no-yes")
            echo "s_client/s_server base test with no ECH, vs. ECH server"
            server_params=" -w -k $scratchdir/$file $vparm "
            client_params=" -s localhost -p 8443 -n -c example.com $vparm -f index.html"
            ;;
        "yes-no")
            echo "s_client/s_server base test with ECH, vs. no-ECH server"
            server_params=" -w $vparm "
            client_params=" -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html"
            ;;
        "no-no")
            echo "s_client/s_server base test with no ECH, vs. no-ECH server"
            server_params=" -w $vparm "
            client_params=" -s localhost -p 8443 -n -c example.com $vparm -f index.html"
            ;;
        "grease-yes")
            echo "s_client/s_server base test with client-greased ECH vs. ECH server"
            server_params=" -w -k $scratchdir/$file $vparm "
            client_params=" -g -s localhost -p 8443 -H example.com $vparm -f index.html"
            ;;
        "grease-no")
            echo "s_client/s_server base test with client-greased ECH" vs. no-ECH server
            server_params=" -w $vparm "
            client_params=" -g -s localhost -p 8443 -H example.com $vparm -f index.html"
            ;;
        "ignore-yes")
            echo "s_client/s_server base test with client random ID ECH vs. ECH server"
            server_params=" -w -k $scratchdir/$file $vparm "
            client_params=" -I -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html"
            ;;
        "ignore-trial")
            echo "s_client/s_server base test with client random ID ECH vs. ECH server with trial decrypt"
            server_params=" -T -w -k $scratchdir/$file $vparm "
            client_params=" -I -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html"
            ;;
    esac
    # start server
    if [[ "$verbose" == "yes" ]]
    then
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh $server_params &
    else
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh $server_params >/dev/null 2>&1 &
    fi
    # wait a bit
    sleep $sleepb4
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (before client)"
        # exiting without cleanup
        exit 19
    fi
    # Try an 'aul client...
    # wait a bit
    sleep $sleepb4
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh $client_params
    else
        $CODETOP/esnistuff/echcli.sh $client_params >/dev/null 2>&1
    fi
    cret=$?
    # kill server
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (after client)"
        # exiting without cleanup
        exit 19
    fi
    kill $pids
    portpid=`netstat -anp 2>/dev/null | grep 8443 | grep openssl | awk '{print $7}' | sed -e 's#/.*##' 2>/dev/null`
    if [[ "$portpid" != "" ]]
    then
        kill $portpid
    fi
    # sleep a bit
    sleep $sleepaftr
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" != "" ]]
    then
        echo "hmm... $pids still running - exiting"
        # exiting without cleanup
        exit 20
    fi
    if [[ "$cret" != "0" ]]
    then
        case $atest in
            "yes-yes")
                ;&
            "no-yes")
                ;&
            "no-no")
                ;&
            "grease-no")
                ;&
            "grease-yes")
                ;&
            "ignore-trial")
                echo "Client failed for $atest - exiting"
                exit 21
                ;;
        esac
    else
        case $atest in
            "yes-no")
                ;&
            "ignore-yes")
                echo "Client didn't fail for $atest - exiting"
                exit 21
                ;;
        esac
    fi
    done

    # TODO: add a test with outer SNI == NONE
fi

if [[ "$skipgood" == "no" ]]
then
for file in *.pem
do
    kem=${file:0:4}
    kdf=${file:5:4}
    aead=${file:10:4}
    echo "s_client/s_server test for kem: $kem, kdf: $kdf, aead: $aead"
    # start server
    if [[ "$verbose" == "yes" ]]
    then
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -w -k $scratchdir/$file $vparm &
    else
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -w -k $scratchdir/$file $vparm >/dev/null 2>&1 &
    fi
    # wait a bit
    sleep $sleepb4
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (before client)"
        # exiting without cleanup
        exit 19
    fi
    # Try an 'aul client...
    # wait a bit
    sleep $sleepb4
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html
    else
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html >/dev/null 2>&1
    fi
    cret=$?
    # kill server
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (after client)"
        # exiting without cleanup
        exit 19
    fi
    kill $pids
    portpid=`netstat -anp 2>/dev/null | grep 8443 | grep openssl | awk '{print $7}' | sed -e 's#/.*##' 2>/dev/null`
    if [[ "$portpid" != "" ]]
    then
        kill $portpid
    fi
    # sleep a bit
    sleep $sleepaftr
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" != "" ]]
    then
        echo "hmm... $pids still running - exiting"
        # exiting without cleanup
        exit 20
    fi
    if [[ "$cret" != "0" ]]
    then
        echo "Client failed for $file - exiting"
        exit 21
    fi
    # jump out after 1st time round the loop if desired
    if [[ "$SHORTCUT" == "yes" ]]
    then
        break
    fi
done
fi

# TBD: test client loading various formats of public key/RR
if [[ "$skiprrs" == "no" ]]
then
for file in *.pem
do
    kem=${file:0:4}
    kdf=${file:5:4}
    aead=${file:10:4}
    echo "s_client input format tests for kem: $kem, kdf: $kdf, aead: $aead"
    # start server
    if [[ "$verbose" == "yes" ]]
    then
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -w -k $scratchdir/$file $vparm &
    else
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -w -k $scratchdir/$file $vparm >/dev/null 2>&1 &
    fi
    # wait a bit
    sleep $sleepb4
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (before client)"
        # exiting without cleanup
        exit 19
    fi
    # Try a few more 'aul clients...

    # wait a bit
    # this is the one we did above, the ECHConfig is supplied in ascii-hex
    sleep $sleepb4
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html
    else
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html >/dev/null 2>&1
    fi
    cret=$?
    if [[ "$cret" != "0" ]]
    then
        echo "Client failed for ascii-hex input from $file - exiting"
        exit 21
    fi

    # wait a bit
    sleep $sleepb4
    # this time the RR value is supplied base64 encoded, so just give the file
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh -P $file -s localhost -p 8443 -H foo.example.com $vparm -f index.html
    else
        $CODETOP/esnistuff/echcli.sh -P $file -s localhost -p 8443 -H foo.example.com $vparm -f index.html >/dev/null 2>&1
    fi
    cret=$?
    if [[ "$cret" != "0" ]]
    then
        echo "Client failed for base64 encoded input from $file - exiting"
        exit 21
    fi

    # kill server
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (after client)"
        # exiting without cleanup
        exit 19
    fi
    kill $pids
    portpid=`netstat -anp 2>/dev/null | grep 8443 | grep openssl | awk '{print $7}' | sed -e 's#/.*##' 2>/dev/null`
    if [[ "$portpid" != "" ]]
    then
        kill $portpid
    fi
    # sleep a bit
    sleep $sleepaftr
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" != "" ]]
    then
        echo "hmm... $pids still running - exiting"
        # exiting without cleanup
        exit 20
    fi
    if [[ "$cret" != "0" ]]
    then
        echo "Client failed for $file - exiting"
        exit 21
    fi
    # jump out after 1st time round the loop if desired
    if [[ "$SHORTCUT" == "yes" ]]
    then
        break
    fi
done
fi

# Try out some deliberate failure cases
if [[ "$skipbad" == "no" ]]
then
for file in *.pem
do
    kem=${file:0:4}
    kdf=${file:5:4}
    aead=${file:10:4}
    # setup to use the wrong file
    badkem=$kem
    badkdf=$(((kdf+1)%4))
    if [[ "$badkdf" == "0" ]]
    then
        badkdf=1
    fi
    badaead=$(((aead+1)%4))
    if [[ "$badaead" == "0" ]]
    then
        badaead=1
    fi
    badfile="$badkem,0x0$badkdf,0x0$badaead.pem"
    if [ ! -f $badfile ]
    then
        echo "Can't see a $badfile - exiting"
        exit 23
    fi
    echo "s_client/s_server deliberate failure test for server's kem: $kem, kdf: $kdf, aead: $aead, vs client's $badfile"
    # start server
    if [[ "$verbose" == "yes" ]]
    then
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -w -k $scratchdir/$file $vparm &
    else
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -w -k $scratchdir/$file $vparm >/dev/null 2>&1 &
    fi
    # wait a bit
    sleep $sleepb4
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (before client)"
        # exiting without cleanup
        exit 19
    fi
    # Try an 'aul client...
    # wait a bit
    sleep $sleepb4
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $badfile` -s localhost -p 8443 -H foo.example.com $vparm -f index.html
    else
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $badfile` -s localhost -p 8443 -H foo.example.com $vparm -f index.html >/dev/null 2>&1
    fi
    cret=$?
    # kill server
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (after client)"
        # exiting without cleanup
        exit 19
    fi
    kill $pids
    portpid=`netstat -anp 2>/dev/null | grep 8443 | grep openssl | awk '{print $7}' | sed -e 's#/.*##' 2>/dev/null`
    if [[ "$portpid" != "" ]]
    then
        kill $portpid
    fi
    # sleep a bit
    sleep $sleepaftr
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" != "" ]]
    then
        echo "hmm... $pids still running - exiting"
        # exiting without cleanup
        exit 20
    fi
    if [[ "$cret" == "0" ]]
    then
        echo "Client didn't fail as expected for server's $file vs. client's $badfile - exiting"
        exit 21
    fi
    # jump out after 1st time round the loop if desired
    if [[ "$SHORTCUT" == "yes" ]]
    then
        break
    fi
done
fi

# Do some session resumption checks
# It'd be better to do fewer of these but with more complex
# setups. One for later.
if [[ "$skipsess" == "no" ]]
then
for file in *.pem
do
    kem=${file:0:4}
    kdf=${file:5:4}
    aead=${file:10:4}
    sessfile="$kem,$kdf,$aead.sess"
    echo "s_client/s_server resumption test for kem: $kem, kdf: $kdf, aead: $aead"
    # start server
    if [[ "$verbose" == "yes" ]]
    then
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -w -k $scratchdir/$file $vparm &
    else
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -w -k $scratchdir/$file $vparm >/dev/null 2>&1 &
    fi
    # wait a bit
    sleep $sleepb4
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (before client)"
        # exiting without cleanup
        exit 19
    fi
    # Try an 'aul initial client...
    # wait a bit
    if [ -f $sessfile ]
    then
        echo "Removing old $sessfile"
        rm $sessfile
    fi
    sleep $sleepb4
    # first go 'round, acquire the session
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile
    else
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile >/dev/null 2>&1
    fi
    cret=$?
    if [ ! -f $sessfile ]
    then
        echo "No sign of $sessfile - exiting"
        exit 87
    fi
    if [[ "$cret" != "0" ]]
    then
        echo "Client failed acquiring session for $file - exiting"
        exit 21
    fi
    # second go 'round, re-use the session
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile
    else
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile >/dev/null 2>&1
    fi
    cret=$?
    if [ ! -f $sessfile ]
    then
        echo "No sign of $sessfile - exiting"
        exit 88
    fi
    if [[ "$cret" != "0" ]]
    then
        echo "Client failed re-using session for $file - exiting"
        exit 21
    fi
    # kill server
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (after client)"
        # exiting without cleanup
        exit 19
    fi
    kill $pids
    portpid=`netstat -anp 2>/dev/null | grep 8443 | grep openssl | awk '{print $7}' | sed -e 's#/.*##' 2>/dev/null`
    if [[ "$portpid" != "" ]]
    then
        kill $portpid
    fi
    # sleep a bit
    sleep $sleepaftr
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" != "" ]]
    then
        echo "hmm... $pids still running - exiting"
        # exiting without cleanup
        exit 20
    fi
    # jump out after 1st time round the loop if desired
    if [[ "$SHORTCUT" == "yes" ]]
    then
        break
    fi
done
fi

# Do some HRR checks
# It'd be better to do fewer of these but with more complex
# setups. One for later.
if [[ "$skiphrr" == "no" ]]
then
for file in *.pem
do
    kem=${file:0:4}
    kdf=${file:5:4}
    aead=${file:10:4}
    echo "s_client/s_server HRR test for kem: $kem, kdf: $kdf, aead: $aead"
    # start server
    if [[ "$verbose" == "yes" ]]
    then
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -R -w -k $scratchdir/$file $vparm &
    else
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -R -w -k $scratchdir/$file $vparm >/dev/null 2>&1 &
    fi
    # wait a bit
    sleep $sleepb4
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (before client)"
        # exiting without cleanup
        exit 19
    fi
    # Try client...
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html
    else
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html  >/dev/null 2>&1
    fi
    cret=$?
    if [[ "$cret" != "0" ]]
    then
        echo "Client failed doing HRR for $file - exiting"
        exit 21
    fi
    # kill server
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (after client)"
        # exiting without cleanup
        exit 19
    fi
    kill $pids
    portpid=`netstat -anp 2>/dev/null | grep 8443 | grep openssl | awk '{print $7}' | sed -e 's#/.*##' 2>/dev/null`
    if [[ "$portpid" != "" ]]
    then
        kill $portpid
    fi
    # sleep a bit
    sleep $sleepaftr
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" != "" ]]
    then
        echo "hmm... $pids still running - exiting"
        # exiting without cleanup
        exit 20
    fi
    # jump out after 1st time round the loop if desired
    if [[ "$SHORTCUT" == "yes" ]]
    then
        break
    fi
done
fi

# Do some early-data checks
if [[ "$skiped" == "no" ]]
then
for file in *.pem
do
    kem=${file:0:4}
    kdf=${file:5:4}
    aead=${file:10:4}
    sessfile="$kem,$kdf,$aead.ed-sess"
    if [ -f $sessfile ]
    then
        echo "Removing old $sessfile"
        rm $sessfile
    fi
    echo "s_client/s_server early-data test for kem: $kem, kdf: $kdf, aead: $aead"
    # start server
    if [[ "$verbose" == "yes" ]]
    then
        # took vparm out here - if it's there, something times out before tickets acquired
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -e -k $scratchdir/$file &
    else
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -e -k $scratchdir/$file $vparm >/dev/null 2>&1 &
    fi
    # wait a bit
    sleep $sleepb4
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (before client)"
        # exiting without cleanup
        exit 19
    fi
    # Try client...
    # first go 'round, acquire the session
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile
    else
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile >/dev/null 2>&1
    fi
    cret=$?
    if [ ! -f $sessfile ]
    then
        echo "No sign of $sessfile - exiting"
        exit 87
    fi
    if [[ "$cret" != "0" ]]
    then
        echo "Client failed acquiring session for $file (ret = $cret) - exiting"
        exit 21
    fi
    # second go 'round, re-use the session
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile -e
    else
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile -e >/dev/null 2>&1
    fi
    cret=$?
    if [[ "$cret" != "0" ]]
    then
        echo "Client failed sending early-data for $file (ret=$cret) - exiting"
        exit 21
    fi
    # kill server
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (after client)"
        # exiting without cleanup
        exit 19
    fi
    kill $pids
    portpid=`netstat -anp 2>/dev/null | grep 8443 | grep openssl | awk '{print $7}' | sed -e 's#/.*##' 2>/dev/null`
    if [[ "$portpid" != "" ]]
    then
        kill $portpid
    fi
    # sleep a bit
    sleep $sleepaftr
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" != "" ]]
    then
        echo "hmm... $pids still running - exiting"
        # exiting without cleanup
        exit 20
    fi
    # jump out after 1st time round the loop if desired
    if [[ "$SHORTCUT" == "yes" ]]
    then
        break
    fi
done
fi

# Do some HRR + early-data checks
if [[ "$skiphrred" == "no" ]]
then
for file in *.pem
do
    kem=${file:0:4}
    kdf=${file:5:4}
    aead=${file:10:4}
    sessfile="$kem,$kdf,$aead.hrr-ed-sess"
    if [ -f $sessfile ]
    then
        echo "Removing old $sessfile"
        rm $sessfile
    fi
    echo "s_client/s_server HRR + early-data test for kem: $kem, kdf: $kdf, aead: $aead"
    # start server
    if [[ "$verbose" == "yes" ]]
    then
        # took vparm out here - if it's there, something times out before tickets acquired
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -R -e -k $scratchdir/$file &
    else
        CFGTOP=$scratchdir $CODETOP/esnistuff/echsvr.sh -R -e -k $scratchdir/$file $vparm >/dev/null 2>&1 &
    fi
    # wait a bit
    sleep $sleepb4
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (before client)"
        # exiting without cleanup
        exit 19
    fi
    # Try client...
    # first go 'round, acquire the session
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile
    else
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile >/dev/null 2>&1
    fi
    cret=$?
    if [ ! -f $sessfile ]
    then
        echo "No sign of $sessfile - exiting"
        exit 87
    fi
    if [[ "$cret" != "0" ]]
    then
        echo "Client failed acquiring session for $file (ret = $cret) - exiting"
        exit 21
    fi
    # second go 'round, re-use the session
    if [[ "$verbose" == "yes" ]]
    then
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile -e
    else
        $CODETOP/esnistuff/echcli.sh -P `$CODETOP/esnistuff/pem2rr.sh -p $file` -s localhost -p 8443 -H foo.example.com $vparm -f index.html -S $sessfile -e >/dev/null 2>&1
    fi
    cret=$?
    if [[ "$cret" != "0" ]]
    then
        echo "Client failed sending early-data for $file (ret=$cret) - exiting"
        exit 21
    fi
    # kill server
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" == "" ]]
    then
        echo "No sign of s_server - exiting (after client)"
        # exiting without cleanup
        exit 19
    fi
    kill $pids
    portpid=`netstat -anp 2>/dev/null | grep 8443 | grep openssl | awk '{print $7}' | sed -e 's#/.*##' 2>/dev/null`
    if [[ "$portpid" != "" ]]
    then
        kill $portpid
    fi
    # sleep a bit
    sleep $sleepaftr
    pids=`ps -ef | grep s_server | grep -v grep | awk '{print $2}'`
    if [[ "$pids" != "" ]]
    then
        echo "hmm... $pids still running - exiting"
        # exiting without cleanup
        exit 20
    fi
    # jump out after 1st time round the loop if desired
    if [[ "$SHORTCUT" == "yes" ]]
    then
        break
    fi
done
fi

# cleanup
cd $startdir
# clear up unless asked, to re-use
if [[ "$KEEP" == "" && "$SCRATCHDIR" == "" ]]
then
    rm -rf $scratchdir
fi

# success exit
echo "Looks like it worked out fine"
exit 0
