# ci-actions

Actions partagées des workflows de l'organisation open-ent.

## `registry-select`

Choisit d'où un build tire `@open-ent/*` (npm) et `org.entcore` (Maven) : **rct-nexus en
premier, GitHub Packages en repli** (ou l'inverse avec `prefer: github`).

- **npm** : pnpm n'accepte qu'un registre par scope. L'action sonde les deux registres, retient
  le premier disponible et, si c'est Nexus, fait pointer `@open-ent` dessus dans le `.npmrc` (et
  dans le lockfile, qui fige les URL GitHub). Les deux registres servent les mêmes tarballs,
  octet pour octet.
- **Maven** : repli natif. `~/.m2/settings.xml` déclare les dépôts disponibles dans l'ordre
  voulu ; Maven passe au suivant, artefact par artefact.

```yaml
- uses: open-ent/ci-actions/registry-select@v1
  with:
    nexus-user: ${{ secrets.NEXUS_USER }}
    nexus-password: ${{ secrets.NEXUS_PASSWORD }}
    github-token: ${{ secrets.OPENENT_PACKAGES_TOKEN }}
```

À placer avant l'installation du frontend ; `actions/setup-java` doit recevoir
`overwrite-settings: false` pour garder le `settings.xml` produit.

Les secrets Nexus doivent être des secrets de **dépôt** : sur l'offre gratuite, un secret
d'organisation arrive vide dans un dépôt privé. L'action ne contient aucun secret ; les
identifiants ne sont jamais écrits en clair dans le `.npmrc` (variable `OEM_NEXUS_NPM_AUTH`,
masquée).

Le `settings.xml` produit déclare les serveurs `github`, `pt-releases` et `pt-public` : les
étapes de publication existantes (`-DrepositoryId=pt-releases` ou `github`) fonctionnent sans
changement.
