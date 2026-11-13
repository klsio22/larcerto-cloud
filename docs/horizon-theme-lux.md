# Tema Horizon Lux (mínimo)

Tema custom do lab: herda o **default** do Horizon e só muda cores/layout. Não usa o Lux do Bootswatch.com (Bootstrap 5 incompatível com o Horizon deste lab).

Referências:

- [Horizon Themes](https://docs.openstack.org/horizon/latest/configuration/themes.html)
- Kolla: `horizon_custom_themes` + `{{ node_custom_config }}/horizon/themes/<name>/`

## Ficheiros

| Path | Papel |
|------|-------|
| [`../kolla-config/config/horizon/themes/lux/_variables.scss`](../kolla-config/config/horizon/themes/lux/_variables.scss) | `@import` default + paleta |
| [`../kolla-config/config/horizon/themes/lux/_styles.scss`](../kolla-config/config/horizon/themes/lux/_styles.scss) | Sidebar / sombra navbar |
| [`../kolla-config/config/horizon/_9999-custom-settings.py`](../kolla-config/config/horizon/_9999-custom-settings.py) | `DEFAULT_THEME = 'lux'` |
| [`../kolla-config/globals.yml`](../kolla-config/globals.yml) | `horizon_custom_themes` |

## Aplicar

```bash
./lab.sh fix-horizon   # só se 409 Conflict
./lab.sh deploy
```

No browser: hard refresh → menu utilizador → **Temas** → **Lux**.

## Rollback

1. Remover `horizon_custom_themes` de `globals.yml`
2. Remover `DEFAULT_THEME` (ou o ficheiro `_9999-custom-settings.py`)
3. Remover a pasta `config/horizon/themes/lux/`
4. `./lab.sh deploy`
