# Use .env as Single Point Of Truth

check for any hardcoded values within the project files, which can be used as variables from .env file.
Replace all hardcoded values in the code with variables from .env
issue command cat .env to see the current variables list.
.env exists in the project and don't recreate it.
It is forbidden to recreate .env file.
Add new keys and values to the .env file, check if they were added there and use the variables in codebase instead of hardcoded values.
Compare .env and .env.example and make sure all variables are in both files.
.env: Contains actual secrets and real configuration for your environment
.env.example: Contains safe placeholders that show other developers what variables they need to set up
Don't Exposed secrets in the example file (security risk)

## Environment Variable Management Commands

```bash
# View current environment variables (contains actual values)
cat .env

# View environment variables template (safe to share)
cat .env.example

# Edit environment variables
nano .env
```
