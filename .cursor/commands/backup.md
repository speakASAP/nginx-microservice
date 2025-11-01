# Backup environment

Make backup for .env file wuth current date.
Check if all values in .env.example are present in .env and vice versa
Use commands cat .env and cat .env.example to see these protected files.
Add all non-secret variable names (keys only, without values) that are missing from .env into .env.example.
Never include secret values in .env.example.
Compare .env and .env.example and make sure all variables are in both files.
.env: Contains actual secrets and real configuration for your environment
.env.example: Contains safe placeholders that show other developers what variables they need to set up
Don't Exposed secrets in the example file (security risk)