"""
Lambda function for RDS snapshots
Author: Andrew Jarombek
Date: 6/8/2019
"""

import os
import boto3
import botocore.config
import json
import subprocess


def create_backup(event, context):
    """
    Create a backup of an RDS MySQL database and store it on S3
    :param event: provides information about the triggering of the function
    :param context: provides information about the execution environment
    :return: True when successful
    """

    os.environ['PATH'] = os.environ['PATH'] + ':' + os.environ['LAMBDA_TASK_ROOT']

    try:
        env = os.environ['ENV']
    except KeyError:
        env = "prod"

    try:
        host = os.environ['DB_HOST']
    except KeyError:
        host = ""

    secretsmanager = boto3.client('secretsmanager')
    response = secretsmanager.get_secret_value(SecretId=f'saints-xctf-rds-{env}-secret')
    secret_string = response.get("SecretString")
    secret_dict = json.loads(secret_string)

    username = secret_dict.get("username")
    password = secret_dict.get("password")

    subprocess.check_call(["cp ./backup.sh /tmp/backup.sh && chmod 755 /tmp/backup.sh"], shell=True)

    subprocess.check_call(["/tmp/backup.sh", env, host, username, password])

    s3 = boto3.resource('s3', 'us-east-1', config=botocore.config.Config(s3={'addressing_style':'path'}))
    s3.meta.client.upload_file('/tmp/backup.sql', f'saints-xctf-db-backups-{env}', 'backup.sql')

    return True
