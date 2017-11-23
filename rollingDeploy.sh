#!/usr/bin/env bash

#########################################################
####      APACHE WEBSERVER LOADBALANCER TWEAK       #####
#########################################################
tweakLB(){
   local server=${1?"${FUNCNAME[0]}: server name/ip needed.."}
   local jbossPort=${2?"${FUNCNAME[0]}: instance port number missing"}
   local lbaction=${3?"${FUNCNAME[0]}: disable/enable ?"}
   
   echo "${FUNCNAME[0]} : INFO : $server : $jbossPort : config changes to take out of rotation"
   cd ${ansibleDir}
   ## take off one instance at a time from load balancer
   if [ "$lbaction" == "disable" ]; then
        #ssh -T $server "sed -i \"s%\(^[ \t]*\)BalancerMember http://localhost:$jbossPort/%\1#BalancerMember http://localhost:$jbossPort/%\" $APACHE_CONFIG"
        ${ansible} all -i "${server}," \
              -m replace -a "dest=$APACHE_CONFIG regexp='(^[ \t]*)BalancerMember http://localhost:${jbossPort}/' replace='\1#BalancerMember http://localhost:${jbossPort}/'"
   fi
   if [ "$lbaction" == "enable" ]; then
         #ssh -T $server "sed -i \"s%\(^[ \t]*\)#BalancerMember http://localhost:$jbossPort/%\1BalancerMember http://localhost:$jbossPort/%\" $APACHE_CONFIG"
         ${ansible} all -i "${server}," \
                -m replace -a "dest=$APACHE_CONFIG regexp='(^[ \t]*)#BalancerMember http://localhost:${jbossPort}/' replace='\1BalancerMember http://localhost:${jbossPort}/'"
   fi

   echo "${FUNCNAME[0]} : INFO : reload apache config gracefully"
   ${ansible} all -i "${server}," -m command -a "warn=false /etc/init.d/httpd graceful"
   [ $? -eq 0 ] || echo "${FUNCNAME[0]}: ERROR : Load balancer $server :  wildfly instance $jbossPort : $lbaction : FAILED"
   return 0
}

####################################
####     MAINTENANCE PAGE      #####
####################################
maintenancePage(){
   local server=${1?"${FUNCNAME[0]}: server name/ip needed.."}
   local lbaction=${2?"${FUNCNAME[0]}: disable/enable ?"}
   cd ${ansibleDir}
   if [ "$lbaction" == "disable" ]; then
      ${ansible} all -i "${server}," \
          -m replace -a "dest=$APACHE_CONFIG regexp='RewriteRule /${APPLICATION_NAME} /maintenance.html \[L\]' replace='#RewriteRule /${APPLICATION_NAME} /maintenance.html [L]'"
   fi 
   if [ "$lbaction" == "enable" ]; then
      ${ansible} all -i "${server}," \
          -m replace -a "dest=$APACHE_CONFIG regexp='#RewriteRule /${APPLICATION_NAME} /maintenance.html \[L\]' replace='RewriteRule /${APPLICATION_NAME} /maintenance.html [L]'"
   fi
   ${ansible} all -i "${server}," -a "warn=false /etc/init.d/httpd graceful"
   [ $? -eq 0 ] || echo "Maintenance page $server :  $lbaction : FAILED"
   return 0
}

########################################
####   CHECK IF SERVICES ARE UP    #####
########################################
checkServices(){
   local server=${1?"${FUNCNAME[0]}: server name/ip needed.."}
   local checkUrl=${2?"${FUNCNAME[0]}: instance url to test needed.."}

   #check until 60 sec if the service is up
   local waitTime=60
   local counter=0
   local serverResp=$(ssh -T $server "curl -sSLI $checkUrl" | grep "HTTP/1.1 200 OK" | awk '{print $(NF-1)" "$NF}'  | sed 's/\n//g')
   until [ "$serverResp" != "200 OK" ]; do
         counter=$(( $counter+1 ))
         serverResp=$(ssh -T $server "curl -sSLI $checkUrl" | grep "HTTP/1.1 200 OK" | awk '{print $(NF-1)" "$NF}')
         [ $counter -eq $waitTime ] && echo "${FUNCNAME[0]}: ERROR : Service not up even after 60 sec. Check logs.." && return 1
         sleep 1
   done
   return 0
}

###################################
####      WILDFLY  ACTION     #####
###################################
wildfly(){
        local server=${1?"${FUNCNAME[0]}: server name/ip needed.."}
        local instance=${2?"${FUNCNAME[0]}: instance needed.."}
        local jbossPort=${3?"${FUNCNAME[0]}: jboss web port needed.."}
        local action=${4?"${FUNCNAME[0]}: what to do ? (start/stop/restart/status)"}
  
        #requirement: wildfly init script is set up for each instance in each server.
        cd ${ansibleDir}
        ${ansible} all -i "${server}," -m command -a "warn=false /etc/init.d/$instance $action"
        [ $? -ne 0 ] && echo "${FUNCNAME[0]}: ERROR : Wildfly $server : $instance : $action" && return 1
        echo "${FUNCNAME[0]}: INFO : Wildfly $server : $instance : $action : success"
   
        checkServices "$server" "http://localhost:$jbossPort" || return 1
        return 0
}

####################################
####     DEPLOY WARFILES       #####
####################################
deploy(){
        local server=${1?"${FUNCNAME[0]}: server name/ip needed.."}
        local jbossDir=${2?"${FUNCNAME[0]}: instance wildfly folders (wildfly1/wildfly2 ?).."}
        local warFile=${3?"${FUNCNAME[0]}: missing war file.."}
   
        warFileName=$(basename $warFile)
        for jbossDir in ${JBOSS_HOME[@]}; do 
            ## Wildfly instance:port mappings, Instance1 wildfly1:8080 , Instance2 wildfly2:8080
            ## Wildfly 1 instance : jbossDir=/usr/local/app-servers/wildfly-8.2.1.Final.server1 , web port=8080
            ## Wildfly 1 instance : jbossDir=/usr/local/app-servers/wildfly-8.2.1.Final.server2 , web port=8081

            [ "$jbossDir" == "/usr/local/app-servers/wildfly-8.2.1.Final.server1" -a "$jbossPort" == "8081" ] && continue
            [ "$jbossDir" == "/usr/local/app-servers/wildfly-8.2.1.Final.server2" -a "$jbossPort" == "8080" ] && continue
            
            cd ${ansibleDir}
            ${ansible} all -i "${server}," \
                    --user=lfpltciadmin --vault-password-file=${ansibleDir}/vaultsecret \
                    -b --become-user=root --become-method=su \
                    -m copy -a "src=$warFile dest=${jbossDir}/standalone/deployments/$warFileName force=yes"
        done
        return 0
}

######################################
####     UNDEPLOY WARFILES       #####
######################################
unDeploy(){
        local server=${1?"${FUNCNAME[0]}: server name/ip needed.."}
        local jbossPort=${2?"${FUNCNAME[0]}: jboss web instance port needed."}
        local warFile=${3?"${FUNCNAME[0]}: missing war file.."}
   
        local fileName=$(basename $warFile)
        local warFileName=${fileName:-NULL}
        for jbossDir in ${JBOSS_HOME[@]}; do
            ## Wildfly instance:port mappings, Instance1 wildfly1:8080 , Instance2 wildfly2:8080
            ## Wildfly 1 instance : jbossDir=/usr/local/app-servers/wildfly-8.2.1.Final.server1 , web port=8080
            ## Wildfly 1 instance : jbossDir=/usr/local/app-servers/wildfly-8.2.1.Final.server2 , web port=8081
            [ "$jbossDir" == "/usr/local/app-servers/wildfly-8.2.1.Final.server1" -a "$jbossPort" == "8081" ] && continue
            [ "$jbossDir" == "/usr/local/app-servers/wildfly-8.2.1.Final.server2" -a "$jbossPort" == "8080" ] && continue
            cd ${ansibleDir}
            ${ansible} all -i "${server}," \
                  --user=lfpltciadmin --vault-password-file=${ansibleDir}/vaultsecret \
                  -b --become-user=root --become-method=su \
                  -m command -a "warn=false rm -vf $jbossDir/standalone/deployments/${warFileName}*"
            
            #${ansible} all -i "${server}," \
            #      --user=lfpltciadmin --vault-password-file=${ansibleDir}/vaultsecret \
            #      -b --become-user=root --become-method=su \
            #      -m shell -a "tail -n0 -f $jbossDir/standalone/log/server.log | while read -t 5 line ; do echo \$line ;"
        done
        return 0
}

checkEnvVars(){
        [ -z "$ENVIRONMENT" ] && echo "ERROR: ENVIRONMENT is not set. Exiting.." && return 1
        [ -z "$WILDFLY_ACTION" ] && echo "ERROR: Missing WILDFLY_ACTION parameter. Exiting.." && return 1
        [ -z "$WAR_FILE" ] && echo "ERROR: Missing WAR_FILE parameter. Exiting.." && return 1
        [ -z "$JBOSS_HOME" ] && echo "ERROR: JBOSS_HOME is not set. Exiting.." && return 1
        [ -z "$JBOSS_WEB_PORTS" ] && echo "ERROR: JBOSS_WEB_PORTS is not set. Exiting.." && return 1
        [ -z "$ENV1_SERVERS" ] && echo "ERROR: Missing ENV1_SERVERS parameter. Exiting.." && return 1
        [ -z "$ENV2_SERVERS" ] && echo "ERROR : Missing ENV2_SERVERS parameter. Exiting.." && return 1
        [ -z "$ENV3_SERVERS" ] && echo "ERROR: ENV3_SERVERS is not set. Exiting.." && return 1
        [ -z "$APACHE_CONFIG" ] && echo "ERROR: Missing APACHE_CONFIG parameter. Exiting.." && return 1
        return 0
}

#######################################
####        MAIN FUNCTION         #####
#######################################
main(){
        checkEnvVars || return 1
        [ "$ENVIRONMENT" == "sit" ] && JBOSS_SERVERS=( ${ENV1_SERVERS} )
        [ "$ENVIRONMENT" == "uat" ] && JBOSS_SERVERS=( ${ENV2_SERVERS} )
        [ "$ENVIRONMENT" == "prod" ] && JBOSS_SERVERS=( ${ENV3_SERVERS} )
     
      #  for server in ${JBOSS_SERVERS[@]}; do
      #      maintenancePage "$server" "enable" || return 1
      #      echo "${FUNCNAME[0]} : INFO : Maintenance page : $server : enabled"
      #  done
  
        for server in ${JBOSS_SERVERS[@]}; do
            for jbossPort in ${JBOSS_WEB_PORTS[@]}; do
                        failureFlag=0
                        ## take off instance from loadbalancer
                        tweakLB "$server" "$jbossPort" "disable"

                        appName=$(basename $WAR_FILE .war)
                        echo "${FUNCNAME[0]} : INFO : Undeploy $appName : instance $jbossPort"
                        local deployState="inprogress"
                        
                        unDeploy "$server" "$jbossPort" "$WAR_FILE"
                        if [ $? -ne 0  ]; then
                                echo "${FUNCNAME[0]} : ERROR : UnDeploying $appName. $server is taken off the loadbalancer. Check logs.."
                                deployState="fail"
                                continue
                        fi
                        sleep 5
            
                        for instance in ${WILDFLY_INSTANCES[@]}; do
                                ## Wildfly instance:port mappings, Instance1 wildfly1:8080 , Instance2 wildfly2:8080
                                ## wildfly1 when web port is 8080
                                ## wildfly2 when web port is 8081
                                [ "$instance" == "wildfly1" -a "$jbossPort" == "8081" ] && continue
                                [ "$instance" == "wildfly2" -a "$jbossPort" == "8080" ] && continue    
                                 
                                echo "${FUNCNAME[0]} : INFO : Starting deployment : $WAR_FILE"
                                deployState="inprogress"

                                deploy "$server" "$jbossDir" "$WAR_FILE"

                                checkServices "$server" "http://localhost:$jbossPort/$appName"
                                [ $? -ne 0  ] && echo "${FUNCNAME[0]} : ERROR : Deploying $file. $server is taken off the loadbalancer. Check logs.." && deployState="fail"
                        done
                       
            ## rejoin instance to loadbalancer
            if [ "$deployState" != "fail" ]; then
               echo "${FUNCNAME[0]} : INFO : Put back in rotation : $server : $jbossPort "
               tweakLB "$server" "$jbossPort" "enable"
            fi
       done
    done

    [  "$deployState" == "fail"  ] && echo "${FUNCNAME[0]} : ERROR : Error in deployment. Check logs.." && return 1
    
    #skip for app2
    #if [ "$APPLICATION_NAME" != "app2" ]; then
    #   for server in ${JBOSS_SERVERS[@]}; do
    #       maintenancePage "$server" "disable"
    #       echo "${FUNCNAME[0]} : INFO : Maintenance page : $server : disabled"
    #   done
    #fi
 
    return 0
}


## JOB DEPENDS ON ENV VARIABLES. 
## FOR NOW, IT IS SET IN JENKINS
## ALL JENKINS/ENV VARIABLES ARE IN ALL CAPS.
## SCRIPTS' LOCAL VARIABLES ARE CAMEL CASED.

## Convert few env variables to array, strip of quotes injected into env by jenkins.
APPLICATION_NAME=( `echo ${APPLICATION} | sed 's/"//g'` )
WILDFLY_INSTANCES=( `echo ${WILDFLY_INSTANCES} | sed 's/"//g'` )
WILDFLY_ACTION=`echo ${WILDFLY_OPERATION} | sed 's/"//g'`
WAR_FILE=`echo ${DEPLOY_WAR_FILE} | sed 's/"//g'`
JBOSS_HOME=( `echo ${WILDFLY_FOLDERS} | sed 's/"//g'` )
JBOSS_WEB_PORTS=( `echo ${WILDFLY_WEB_PORTS} | sed 's/"//g'` )

ENV1_SERVERS=`echo ${ENV1_SERVERS_LIST} |  sed 's/"//g'`
ENV2_SERVERS=`echo ${ENV2_SERVERS_LIST} |  sed 's/"//g'`
ENV3_SERVERS=`echo ${ENV3_SERVERS_LIST} | sed 's/"//g'`

APACHE_CONFIG=`echo ${APACHE_CONFIG_FILE} | sed 's/"//g'`

ansibleDir="ANSIBLE_DIR"
ansible="ANSIBLE_EXECUTABLE"
main || exit 1
