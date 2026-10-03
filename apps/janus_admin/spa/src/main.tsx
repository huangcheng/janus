import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import {
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
  redirect,
  RouterProvider,
} from '@tanstack/react-router'
import '@fontsource-variable/geist'
import '@fontsource-variable/geist-mono'
import './styles.css'
import { api, setCsrf } from './api'
import { ToastHost } from './components'
import { Audit, Dashboard, Keys, Login, Models, Providers } from './pages'

const rootRoute = createRootRoute({
  component: () => (
    <ToastHost>
      <Outlet />
    </ToastHost>
  ),
})

// Outside the auth guard: minimal layout, no chrome.
const loginRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/login',
  component: Login,
})

// Auth guard: verify the session (and pick up the CSRF token) before
// any console route renders.
const authLayout = createRoute({
  getParentRoute: () => rootRoute,
  id: '_auth',
  beforeLoad: async () => {
    try {
      const s = await api('/session')
      if (s?.csrf) setCsrf(s.csrf)
    } catch {
      throw redirect({ to: '/login' })
    }
  },
  component: () => <Outlet />,
})

const indexRoute = createRoute({ getParentRoute: () => authLayout, path: '/', component: Dashboard })
const providersRoute = createRoute({ getParentRoute: () => authLayout, path: '/providers', component: Providers })
const modelsRoute = createRoute({ getParentRoute: () => authLayout, path: '/models', component: Models })
const keysRoute = createRoute({ getParentRoute: () => authLayout, path: '/keys', component: Keys })
const auditRoute = createRoute({ getParentRoute: () => authLayout, path: '/audit', component: Audit })

const routeTree = rootRoute.addChildren([
  loginRoute,
  authLayout.addChildren([indexRoute, providersRoute, modelsRoute, keysRoute, auditRoute]),
])

const router = createRouter({ routeTree, basepath: '/admin' })

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router
  }
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>,
)
