aws ecs list-task-definitions | jq -r '.taskDefinitionArns[]' | while read taskDef; do
    aws ecs deregister-task-definition --task-definition "$taskDef"
done