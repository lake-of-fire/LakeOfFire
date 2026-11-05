export const element = (localName, namespaceURI, attributes = {}, children = [], textContent = '') => ({
    localName, namespaceURI, children, childNodes: children, textContent, nodeType: 1,
    id: attributes.id ?? '',
    getAttribute: name => attributes[name] ?? null,
    setAttribute: (name, value) => { attributes[name] = value },
    hasAttribute: name => Object.hasOwn(attributes, name),
    hasAttributeNS: () => false,
    getElementsByTagNameNS: (namespace, name) => children.flatMap(descendants)
        .filter(node => node.namespaceURI === namespace && node.localName === name),
})
const descendants = node => [node, ...node.children.flatMap(descendants)]
export const xmlDocument = root => {
    const all = descendants(root)
    const doc = {
        documentElement: root, firstChild: null,
        lookupNamespaceURI: () => root.namespaceURI,
        lookupPrefix: () => null,
        querySelector: () => null,
        querySelectorAll: selector => selector === 'link[href]'
            ? all.filter(node => node.localName === 'link') : [],
        getElementsByTagName: name => all.filter(node => name === '*' || node.localName === name),
        getElementsByTagNameNS: (namespace, name) => all.filter(node => node.namespaceURI === namespace && node.localName === name),
        getElementById: id => all.find(node => node.id === id),
    }
    for (const node of all) {
        node.ownerDocument = doc
        for (const child of node.children) child.parentNode = node
    }
    return doc
}
