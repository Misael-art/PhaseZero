Name:           phasezero-control-center
Version:        1.5.0
Release:        1%{?dist}
Summary:        PhaseZero native Linux control center
License:        MIT
URL:            https://github.com/Misael-art/PhaseZero
Source0:        https://github.com/Misael-art/PhaseZero/archive/refs/tags/v%{version}.tar.gz
BuildArch:      noarch
Requires:       python3
Requires:       python3-pyside6
Requires:       bash
Requires:       jq

%description
Native Qt6 frontend for PhaseZero Linux automation. Every mutation requires
a safe preview and explicit confirmation.

%prep
%autosetup -n PhaseZero-%{version}

%build

%install
install -d %{buildroot}%{_libdir}/phasezero %{buildroot}%{_bindir}
install -d %{buildroot}%{_datadir}/applications %{buildroot}%{_datadir}/metainfo
install -d %{buildroot}%{_datadir}/icons/hicolor/scalable/apps
cp -a linux profiles assets version.json %{buildroot}%{_libdir}/phasezero/
install -m755 packaging/linux/phasezero-control-center %{buildroot}%{_bindir}/
install -m644 packaging/linux/io.phasezero.ControlCenter.desktop %{buildroot}%{_datadir}/applications/
install -m644 packaging/linux/io.phasezero.ControlCenter.metainfo.xml %{buildroot}%{_datadir}/metainfo/
install -m644 packaging/linux/io.phasezero.ControlCenter.svg %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/

%files
%{_bindir}/phasezero-control-center
%{_libdir}/phasezero
%{_datadir}/applications/io.phasezero.ControlCenter.desktop
%{_datadir}/metainfo/io.phasezero.ControlCenter.metainfo.xml
%{_datadir}/icons/hicolor/scalable/apps/io.phasezero.ControlCenter.svg

%changelog
* Fri Jul 11 2026 PhaseZero <noreply@phasezero.local> - 1.5.0-1
- Context inspector workspace and complete native UI information architecture.

* Thu Jul 09 2026 PhaseZero <noreply@phasezero.local> - 1.4.1-1
- Installation, packaging and AI tooling robustness fixes.
* Wed Jul 08 2026 PhaseZero <noreply@phasezero.local> - 1.3.0-1
- Homelab CX: rich JSON status/plan, secret generation, access modes
  (local/tailscale/lan), open/logs/backup/restore/update, CasaOS compatibility gate.
* Mon Jul 06 2026 PhaseZero <noreply@phasezero.local> - 1.1.0-1
- SRM coverage, safe Switch scanning, launchers, game optimizers and AI proxies.
