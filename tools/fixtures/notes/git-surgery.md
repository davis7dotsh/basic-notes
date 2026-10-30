# git surgery

## move a branch that was based on the wrong thing
feature-b was branched off feature-a, but feature-a got squash-merged. replay only b's commits onto main:
```bash
git rebase --onto main feature-a feature-b
```

## undo the last commit, keep changes
```bash
git reset --soft HEAD~1
```

## find which commit broke it
```bash
git bisect start
git bisect bad
git bisect good v1.4.0
# ... test ...
git bisect run pnpm test -- --run src/search.test.ts
git bisect reset
```

## recover "lost" commits
```bash
git reflog
git checkout -b rescue HEAD@{5}
```

## remove a file from history (leaked .env 😬)
```bash
git filter-repo --path .env --invert-paths
```
then rotate the keys anyway
