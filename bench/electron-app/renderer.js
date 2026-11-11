const $ = (id) => document.getElementById(id);
$('submit').onclick = async () => {
  $('status').textContent = await window.bench.submit({
    name: $('name').value, color: $('color').value, agree: $('agree').checked, at: new Date().toISOString(),
  });
};
$('export').onclick = async () => { $('status').textContent = await window.bench.exportReport(); };
