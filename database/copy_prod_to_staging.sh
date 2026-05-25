#!/bin/bash

# https://stackoverflow.com/questions/3195125/copy-a-table-from-one-database-to-another-in-postgres
source ../misc/.env

psql ${HIVETRACKS_DEV_DB} <<EOF
	\x
	DROP DATABASE IF EXISTS hivetracks_staging;
	CREATE DATABASE hivetracks_staging;
EOF

tables='"Apiary" "Beekeeper" "Bloom" "Record" "ToDo" "ChecklistItem" "Colony" "Group" "Hive" "Message" "PasswordResetCode" "Queen" "Tokens" "Photo" "_prisma_migrations" "_beekeeperMessagesReceived"'
relation_tables='"ApiaryToBeekeeper" "ApiaryToHive" "ApiaryToRecord" "ApiaryToToDo" "BeekeeperToGroup" "ColonyToHive" "ColonyToQueen" "HiveToRecord" "HiveToToDo"'

echo "Copying $TABLE table from $HIVETRACKS_PROD_DB to $HIVETRACKS_STAGING_DB.."
for TABLE in $tables
do
	echo "On ${TABLE}"
	pg_dump -t "${TABLE}" ${HIVETRACKS_PROD_DB} | psql ${HIVETRACKS_STAGING_DB} >/dev/null
done

echo "Copying relation $TABLE table from prod to staging..."
for TABLE in $relation_tables
do
	echo "On ${TABLE}"
	pg_dump -t "${TABLE}" ${HIVETRACKS_PROD_DB} | psql ${HIVETRACKS_STAGING_DB} >/dev/null
done