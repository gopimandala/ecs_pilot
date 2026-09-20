import json
import os
import time
import boto3

REGION = os.getenv("AWS_REGION", "ap-south-1")
QUEUE_URL = os.environ["QUEUE_URL"]
DLQ_URL = os.environ["DLQ_URL"]
CLUSTER = os.environ["ECS_CLUSTER"]
TASK_DEFINITION = os.environ["TASK_DEFINITION"]
WORKER_CONTAINER = os.getenv("WORKER_CONTAINER", "worker")
MAX_TASKS = int(os.getenv("MAX_TASKS", "1"))
MAX_ATTEMPTS = int(os.getenv("MAX_ATTEMPTS", "2"))
TASK_TIMEOUT_SECONDS = int(os.getenv("TASK_TIMEOUT_SECONDS", "30"))
SUBNET_ID = os.environ["SUBNET_ID"]
SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]
DEDUP_TABLE = os.environ["DEDUP_TABLE"]

sqs = boto3.client("sqs", region_name=REGION)
ecs = boto3.client("ecs", region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)
dedup_table = dynamodb.Table(DEDUP_TABLE)


def receive_messages(limit):
    response = sqs.receive_message(
        QueueUrl=QUEUE_URL,
        MaxNumberOfMessages=min(limit, 10),
        WaitTimeSeconds=10,
        VisibilityTimeout=180,
        AttributeNames=["ApproximateReceiveCount"],
    )
    return response.get("Messages", [])


def start_task(message):
    body = json.loads(message["Body"])
    overrides = {"containerOverrides": [{"name": WORKER_CONTAINER}]}
    if "delay_s" in body:
        overrides["containerOverrides"][0]["environment"] = [
            {"name": "DELAY_S", "value": str(body["delay_s"])}
        ]

    response = ecs.run_task(
        cluster=CLUSTER,
        taskDefinition=TASK_DEFINITION,
        clientToken=f"{message['MessageId']}-{time.time_ns()}",
        launchType="FARGATE",
        networkConfiguration={
            "awsvpcConfiguration": {
                "subnets": [SUBNET_ID],
                "securityGroups": [SECURITY_GROUP_ID],
                "assignPublicIp": "ENABLED",
            }
        },
        overrides=overrides,
    )
    failures = response.get("failures", [])
    if failures or not response.get("tasks"):
        reason = failures[0].get("reason", "ECS did not start a task") if failures else "ECS did not start a task"
        raise RuntimeError(reason)
    return response["tasks"][0]["taskArn"]


def claim_message(message):
    message_id = message["MessageId"]
    try:
        dedup_table.put_item(
            Item={"message_id": message_id, "status": "starting"},
            ConditionExpression="attribute_not_exists(message_id)",
        )
        return True, None
    except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        item = dedup_table.get_item(Key={"message_id": message_id}).get("Item", {})
        return False, item.get("task_arn")


def record_task(message, task_arn):
    dedup_table.update_item(
        Key={"message_id": message["MessageId"]},
        UpdateExpression="SET #status = :status, task_arn = :task_arn, expires_at = :expires_at",
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={
            ":status": "running",
            ":task_arn": task_arn,
            ":expires_at": int(time.time()) + 86400,
        },
    )


def release_message(message):
    dedup_table.delete_item(Key={"message_id": message["MessageId"]})


def update_message_status(message, status):
    dedup_table.update_item(
        Key={"message_id": message["MessageId"]},
        UpdateExpression="SET #status = :status, expires_at = :expires_at",
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={
            ":status": status,
            ":expires_at": int(time.time()) + 86400,
        },
    )


def task_succeeded(task):
    containers = task.get("containers", [])
    if not containers:
        return False
    if any("exitCode" not in container or container["exitCode"] is None for container in containers):
        return False
    return all(container["exitCode"] == 0 for container in containers)


def task_timed_out(task_state):
    # Absolute wall-clock metric check
    return time.time() >= task_state["deadline"]


def finish_message(message, succeeded):
    if succeeded:
        sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=message["ReceiptHandle"])
        update_message_status(message, "completed")
        return

    receive_count = int(message.get("Attributes", {}).get("ApproximateReceiveCount", "1"))
    if receive_count >= MAX_ATTEMPTS:
        sqs.send_message(QueueUrl=DLQ_URL, MessageBody=message["Body"])
        sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=message["ReceiptHandle"])
        update_message_status(message, "failed_dlq")
    else:
        sqs.change_message_visibility(
            QueueUrl=QUEUE_URL,
            ReceiptHandle=message["ReceiptHandle"],
            VisibilityTimeout=0,
        )
        release_message(message)


def stop_timed_out_task(task_arn, task_state):
    if task_state["timed_out"] or not task_timed_out(task_state):
        return

    task_state["timed_out"] = True
    try:
        ecs.stop_task(
            cluster=CLUSTER,
            task=task_arn,
            reason=f"Task exceeded {TASK_TIMEOUT_SECONDS}-second timeout",
        )
        print(f"stopping timed-out task {task_arn}", flush=True)
    except Exception as error:
        print(f"could not stop timed-out task {task_arn}: {error}", flush=True)


def completed_tasks(response, running):
    visible = {task["taskArn"] for task in response.get("tasks", [])}
    completed = []

    for task in response.get("tasks", []):
        task_arn = task["taskArn"]
        task_state = running[task_arn]

        # 1. Evaluate if it has overstayed its wall-clock lease boundary
        if task_timed_out(task_state):
            task_state["timed_out"] = True

        # 2. Actively kill if it is still running past the deadline
        if task.get("lastStatus") != "STOPPED":
            stop_timed_out_task(task_arn, task_state)
            continue

        # 3. Retrospective Check: Dead container must pass execution validation AND timing thresholds
        succeeded = task_succeeded(task) and not task_state["timed_out"]
        completed.append((task_arn, succeeded))

    # 4. Handle Ghost Mitigation: Clean up tasks that vanish entirely from AWS tracking responses
    completed.extend((task_arn, False) for task_arn in set(running) - visible)
    return completed


def check_running_tasks(running):
    response = ecs.describe_tasks(cluster=CLUSTER, tasks=list(running))
    return completed_tasks(response, running)


def finalize_tasks(completed, running):
    for task_arn, succeeded in completed:
        task_state = running[task_arn]
        try:
            finish_message(task_state["message"], succeeded)
            del running[task_arn]
            print(f"task {task_arn} {'succeeded' if succeeded else 'failed'}", flush=True)
        except Exception as error:
            print(f"could not finalize task {task_arn}: {error}", flush=True)


def track_message(message, running):
    body = json.loads(message["Body"])
    claimed, task_arn = claim_message(message)
    if claimed:
        task_arn = start_task(message)
        record_task(message, task_arn)
    elif task_arn is None:
        sqs.change_message_visibility(
            QueueUrl=QUEUE_URL,
            ReceiptHandle=message["ReceiptHandle"],
            VisibilityTimeout=30,
        )
        return
    # Fixed deadline configuration anchor set once at execution startup
    running[task_arn] = {
        "message": message,
        "timed_out": False,
        "deadline": time.time() + TASK_TIMEOUT_SECONDS,
    }
    print(
        f"tracking task {task_arn}; delay_s={body.get('delay_s', 0)}; "
        f"timeout={TASK_TIMEOUT_SECONDS}s",
        flush=True,
    )


def start_available_tasks(running):
    slots = MAX_TASKS - len(running)
    for message in receive_messages(slots) if slots > 0 else []:
        try:
            track_message(message, running)
        except Exception as error:
            print(f"could not start task: {error}", flush=True)
            finish_message(message, False)
            release_message(message)


def main():
    running = {}
    print(
        f"monitor started for {TASK_DEFINITION}; max tasks={MAX_TASKS}; "
        f"task timeout={TASK_TIMEOUT_SECONDS}s",
        flush=True,
    )

    while True:
        if running:
            finalize_tasks(check_running_tasks(running), running)
        start_available_tasks(running)
        time.sleep(10)


if __name__ == "__main__":
    main()
