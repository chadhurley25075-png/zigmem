// zigmem panel: confirm before destructive-looking buttons, copy a freshly shown token. No storage, no network.
(function () {
  "use strict";
  document.addEventListener("click", function (e) {
    var t = e.target;
    if (!(t instanceof HTMLElement)) return;
    var msg = t.getAttribute("data-confirm");
    if (msg && !window.confirm(msg)) e.preventDefault();
  });
  var btn = document.getElementById("copytok");
  var tok = document.getElementById("newtok");
  if (btn && tok) {
    btn.addEventListener("click", function () {
      var text = tok.textContent || "";
      function selectIt() {
        var r = document.createRange();
        r.selectNodeContents(tok);
        var s = window.getSelection();
        s.removeAllRanges();
        s.addRange(r);
      }
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(function () { btn.textContent = "Copied"; }, selectIt);
      } else {
        selectIt();
        btn.textContent = "Selected: copy it now";
      }
    });
  }
})();
