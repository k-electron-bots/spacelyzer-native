use crate::category::{Category, CATEGORY_COUNT};

pub type NodeId = u32;
pub const NO_NODE: NodeId = u32::MAX;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    File = 0,
    Directory = 1,
    /// Application bundle (.app etc). Measured whole; the treemap does not descend into it.
    Package = 2,
    Symlink = 3,
}

impl Kind {
    pub fn from_u8(v: u8) -> Kind {
        match v {
            1 => Kind::Directory,
            2 => Kind::Package,
            3 => Kind::Symlink,
            _ => Kind::File,
        }
    }
}

/// Structure-of-arrays arena. Children of a node are contiguous, sorted by size
/// descending, so `children(id)` is a slice range and layout never sorts.
#[derive(Default)]
pub struct Tree {
    pub(crate) names: Vec<Box<str>>,
    pub(crate) parent: Vec<NodeId>,
    pub(crate) kind: Vec<u8>,
    pub(crate) category: Vec<u8>,
    /// Cumulative allocated bytes (own bytes for files).
    pub(crate) size: Vec<u64>,
    pub(crate) first_child: Vec<NodeId>,
    pub(crate) child_count: Vec<u32>,
    pub(crate) root_path: String,
    pub skipped: Vec<Skipped>,
    pub items: u64,
    pub cancelled: bool,
}

#[derive(Clone, Debug)]
pub struct Skipped {
    pub path: String,
    pub reason: SkipReason,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SkipReason {
    PermissionDenied = 0,
    Unreadable = 1,
    SeparateVolume = 2,
    UserExcluded = 3,
}

impl Tree {
    pub fn len(&self) -> usize {
        self.names.len()
    }
    pub fn is_empty(&self) -> bool {
        self.names.is_empty()
    }
    pub fn root(&self) -> NodeId {
        0
    }
    pub fn root_path(&self) -> &str {
        &self.root_path
    }
    pub fn name(&self, id: NodeId) -> &str {
        &self.names[id as usize]
    }
    pub fn size(&self, id: NodeId) -> u64 {
        self.size[id as usize]
    }
    pub fn kind(&self, id: NodeId) -> Kind {
        Kind::from_u8(self.kind[id as usize])
    }
    pub fn category(&self, id: NodeId) -> Category {
        Category::from_u8(self.category[id as usize])
    }
    pub fn parent(&self, id: NodeId) -> Option<NodeId> {
        let p = self.parent[id as usize];
        (p != NO_NODE).then_some(p)
    }
    pub fn child_count(&self, id: NodeId) -> u32 {
        self.child_count[id as usize]
    }
    pub fn children(&self, id: NodeId) -> std::ops::Range<NodeId> {
        let f = self.first_child[id as usize];
        if f == NO_NODE {
            0..0
        } else {
            f..f + self.child_count[id as usize]
        }
    }

    /// Absolute path of a node.
    pub fn path(&self, id: NodeId) -> String {
        let mut parts: Vec<&str> = Vec::new();
        let mut cur = id;
        while let Some(p) = self.parent(cur) {
            parts.push(self.name(cur));
            cur = p;
        }
        let mut out = self.root_path.clone();
        for p in parts.iter().rev() {
            if !out.ends_with('/') {
                out.push('/');
            }
            out.push_str(p);
        }
        out
    }

    /// Resolve an absolute path back to a node, if it lies under the scanned root.
    pub fn find(&self, path: &str) -> Option<NodeId> {
        let rest = path.strip_prefix(self.root_path.trim_end_matches('/'))?;
        let mut cur = self.root();
        for comp in rest.split('/').filter(|c| !c.is_empty()) {
            cur = self.children(cur).find(|&c| self.name(c) == comp)?;
        }
        Some(cur)
    }

    /// Bytes and item counts per category over the whole tree (files only).
    pub fn category_totals(&self) -> [(u64, u64); CATEGORY_COUNT] {
        let mut out = [(0u64, 0u64); CATEGORY_COUNT];
        for i in 0..self.len() {
            let k = self.kind[i];
            if k == Kind::Directory as u8 {
                continue;
            }
            // Packages are aggregated by the whole bundle's size; their inner files are
            // not separate nodes at this level when the package is collapsed.
            let c = self.category[i] as usize;
            out[c].0 += self.own_bytes(i as NodeId);
            out[c].1 += 1;
        }
        out
    }

    /// Bytes owned directly by this node (cumulative minus children).
    pub fn own_bytes(&self, id: NodeId) -> u64 {
        let r = self.children(id);
        if r.is_empty() {
            return self.size[id as usize];
        }
        let kids: u64 = r.map(|c| self.size[c as usize]).sum();
        self.size[id as usize].saturating_sub(kids)
    }

    /// The `n` largest regular files, largest first.
    pub fn largest_files(&self, n: usize) -> Vec<NodeId> {
        let mut v: Vec<NodeId> = (0..self.len() as NodeId)
            .filter(|&i| self.kind[i as usize] == Kind::File as u8)
            .collect();
        let n = n.min(v.len());
        if n == 0 {
            return vec![];
        }
        v.select_nth_unstable_by_key(n - 1, |&i| std::cmp::Reverse(self.size[i as usize]));
        v.truncate(n);
        v.sort_by_key(|&i| std::cmp::Reverse(self.size[i as usize]));
        v
    }

    /// Remove a subtree from the result (after a move to Trash) and fix ancestor totals.
    /// The node stays in the arena with size 0 and is hidden from its parent's child list
    /// by zeroing; callers re-layout afterwards.
    pub fn forget(&mut self, id: NodeId) {
        let removed = self.size[id as usize];
        if removed == 0 && self.kind[id as usize] == Kind::Directory as u8 {
            return;
        }
        let mut stack = vec![id];
        while let Some(n) = stack.pop() {
            self.size[n as usize] = 0;
            for c in self.children(n) {
                stack.push(c);
            }
        }
        let mut cur = self.parent(id);
        while let Some(p) = cur {
            self.size[p as usize] = self.size[p as usize].saturating_sub(removed);
            cur = self.parent(p);
        }
    }
}
